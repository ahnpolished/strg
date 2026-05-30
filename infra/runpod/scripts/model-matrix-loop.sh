#!/usr/bin/env bash
# model-matrix-loop.sh - Run RunPod model tests in parallel by model.
#
# Provisions up to --max-parallel pods in a single Terraform apply, assigns one
# model per pod, runs pod-tests.sh concurrently, writes one log per model, then
# tears down the batch before starting the next batch. This avoids Terraform
# state races from running test-loop.sh multiple times in parallel.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$TF_DIR/../.." && pwd)"

DEFAULT_MODELS="internvl2,florence2,qwen2-vl,donut"
MODELS_CSV="$DEFAULT_MODELS"
MAX_PARALLEL=3
MAX_PARALLEL_HARD_CAP=3
MAX_COST_PER_HOUR="1.00"
GPU_TYPE_IDS_CSV="NVIDIA A40,NVIDIA RTX A6000,NVIDIA GeForce RTX 4090,NVIDIA RTX 6000 Ada Generation,NVIDIA GeForce RTX 3090,NVIDIA RTX A5000"
CLOUD_TYPE=""
SSH_KEY=""
for _k in "${HOME}/.ssh/id_ed25519" "${HOME}/.ssh/id_rsa" "${HOME}/.ssh/id_ecdsa"; do
  if [[ -f "$_k" ]]; then SSH_KEY="$_k"; break; fi
done
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_rsa}"
SSH_USER="root"
TEST_SCRIPT="$SCRIPT_DIR/pod-tests.sh"
REMOTE_BASE="/workspace/strg-matrix"
NO_SYNC=0
SSH_TIMEOUT=600
BATCH_TIMEOUT=1800
LOG_DIR="$TF_DIR/logs"
RUN_ID="$(date '+%Y%m%d-%H%M%S')"
DRY_RUN=0
LAST_BATCH_STATUS=0

usage() {
  cat <<'USAGE'
Usage: infra/runpod/scripts/model-matrix-loop.sh [OPTIONS]

Run model smoke/evaluation jobs in parallel by model without Terraform state races.
The script provisions one batch of pods at a time, up to --max-parallel, runs one
model per pod, tears that batch down, then continues with any remaining models.

Options:
  --models CSV           Comma-separated models to test
                         (default: internvl2,florence2,qwen2-vl,donut)
  --max-parallel N       Maximum concurrent pods/models per batch (default: 3, hard cap: 3)
  --max-cost-per-hour N  Refuse to run pods above this hourly cost (default: 1.00)
  --gpu-type-ids CSV     Ordered RunPod GPU fallback list. Defaults to cheaper GPUs:
                         A40, RTX A6000, RTX 4090, RTX 6000 Ada, RTX 3090, RTX A5000
  --cloud-type TYPE      Override RunPod cloud type for this run: COMMUNITY or SECURE
  --ssh-key PATH         SSH private key (default: auto-detected)
  --ssh-user USER        SSH user on pod (default: root)
  --test-script PATH     Script to run on pod (default: scripts/pod-tests.sh)
  --remote-base PATH     Remote base directory for per-model workspaces
                         (default: /workspace/strg-matrix)
  --no-sync              Skip rsync step
  --ssh-timeout SECS     Max wait for IP+port assignment and SSH (default: 600)
  --batch-timeout SECS   Hard wall-clock limit per batch; 0 disables (default: 1800)
  --log-dir PATH         Directory for per-model logs (default: infra/runpod/logs)
  --run-id ID            Run identifier used in log/workspace names (default: timestamp)
  --dry-run              Print what would run, no provisioning
  -h, --help             Show this help

Prerequisites:
  export TF_VAR_ssh_public_key="$(cat ~/.ssh/id_ed25519.pub)"
  export RUNPOD_API_KEY="<your-key>"

Secrets:
  WANDB_API_KEY is forwarded to pods if present, but never printed by this script.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --models)          MODELS_CSV="$2"; shift 2 ;;
    --max-parallel)    MAX_PARALLEL="$2"; shift 2 ;;
    --max-cost-per-hour) MAX_COST_PER_HOUR="$2"; shift 2 ;;
    --gpu-type-ids)    GPU_TYPE_IDS_CSV="$2"; shift 2 ;;
    --cloud-type)      CLOUD_TYPE="$2"; shift 2 ;;
    --ssh-key)         SSH_KEY="$2"; shift 2 ;;
    --ssh-user)        SSH_USER="$2"; shift 2 ;;
    --test-script)     TEST_SCRIPT="$2"; shift 2 ;;
    --remote-base)     REMOTE_BASE="$2"; shift 2 ;;
    --no-sync)         NO_SYNC=1; shift ;;
    --ssh-timeout)     SSH_TIMEOUT="$2"; shift 2 ;;
    --batch-timeout)   BATCH_TIMEOUT="$2"; shift 2 ;;
    --log-dir)         LOG_DIR="$2"; shift 2 ;;
    --run-id)          RUN_ID="$2"; shift 2 ;;
    --dry-run)         DRY_RUN=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

log()  { echo "[$(date '+%H:%M:%S')] $*" >&2; }
info() { log "INFO  $*"; }
warn() { log "WARN  $*"; }
err()  { log "ERROR $*"; }

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

sanitize_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '-' | sed 's/-\+/-/g; s/^-//; s/-$//'
}

split_models() {
  local csv="$1"
  local -a raw=()
  IFS=',' read -r -a raw <<< "$csv"
  MODELS=()
  local item
  for item in "${raw[@]}"; do
    item="$(trim "$item")"
    [[ -n "$item" ]] && MODELS+=("$item")
  done
}

csv_to_tf_string_list() {
  local csv="$1"
  python3 - "$csv" <<'PY'
import json, sys
items = [item.strip() for item in sys.argv[1].split(',') if item.strip()]
print(json.dumps(items))
PY
}

check_integer() {
  local name="$1" value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    err "$name must be a non-negative integer: $value"
    exit 2
  fi
}

check_number() {
  local name="$1" value="$2"
  python3 - "$value" <<'PY' || { err "$name must be a number: $value"; exit 2; }
import sys
value = float(sys.argv[1])
if value < 0:
    raise SystemExit(1)
PY
}

check_prereqs() {
  check_integer "--max-parallel" "$MAX_PARALLEL"
  check_integer "--ssh-timeout" "$SSH_TIMEOUT"
  check_integer "--batch-timeout" "$BATCH_TIMEOUT"
  check_number "--max-cost-per-hour" "$MAX_COST_PER_HOUR"
  if [[ "$MAX_PARALLEL" -lt 1 ]]; then
    err "--max-parallel must be at least 1"
    exit 2
  fi
  if [[ "$MAX_PARALLEL" -gt "$MAX_PARALLEL_HARD_CAP" ]]; then
    err "--max-parallel is capped at ${MAX_PARALLEL_HARD_CAP} to control GPU spend"
    exit 2
  fi

  split_models "$MODELS_CSV"
  if [[ "${#MODELS[@]}" -eq 0 ]]; then
    err "--models did not include any models"
    exit 2
  fi

  local missing=0
  for cmd in terraform ssh rsync python3 sed tr awk; do
    if ! command -v "$cmd" &>/dev/null; then
      err "Required command not found: $cmd"
      missing=1
    fi
  done
  [[ $missing -eq 0 ]] || exit 1

  if [[ ! -f "$SSH_KEY" ]]; then
    err "SSH private key not found: $SSH_KEY (override with --ssh-key)"
    exit 1
  fi
  if [[ ! -f "$TEST_SCRIPT" ]]; then
    err "Test script not found: $TEST_SCRIPT (override with --test-script)"
    exit 1
  fi

  local pub_key="${SSH_KEY}.pub"
  if [[ -z "${TF_VAR_ssh_public_key:-}" ]]; then
    if [[ ! -f "$pub_key" ]]; then
      err "SSH public key not found: $pub_key"
      err "Either create it or set TF_VAR_ssh_public_key in your environment."
      exit 1
    fi
    export TF_VAR_ssh_public_key
    TF_VAR_ssh_public_key="$(cat "$pub_key")"
    info "Using SSH public key: $pub_key"
  else
    info "Using TF_VAR_ssh_public_key from environment."
  fi

  if [[ -z "${RUNPOD_API_KEY:-}" ]]; then
    err "RUNPOD_API_KEY is not set (required for Terraform provider and RunPod REST API)."
    exit 1
  fi

  mkdir -p "$LOG_DIR"
}

tf() {
  terraform -chdir="$TF_DIR" "$@"
}

provision_batch() {
  local count="$1"
  local gpu_type_ids_tf
  gpu_type_ids_tf="$(csv_to_tf_string_list "$GPU_TYPE_IDS_CSV")"
  info "Provisioning ${count} pod(s) for matrix batch..."
  info "GPU fallback list: ${GPU_TYPE_IDS_CSV}"
  if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run] terraform apply -auto-approve -var pod_count=${count} -var max_pod_count_guardrail=${MAX_PARALLEL} -var gpu_type_ids=${gpu_type_ids_tf}"
    return 0
  fi
  local -a tf_args=(
    -auto-approve
    -var "pod_count=${count}"
    -var "max_pod_count_guardrail=${MAX_PARALLEL}"
    -var "gpu_type_ids=${gpu_type_ids_tf}"
  )
  if [[ -n "$CLOUD_TYPE" ]]; then
    tf_args+=(-var "cloud_type=${CLOUD_TYPE}")
  fi
  tf apply "${tf_args[@]}"
}

teardown_batch() {
  info "Tearing down matrix batch pods..."
  if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run] terraform destroy -auto-approve -target=runpod_pod.trainer"
    return 0
  fi
  tf destroy -auto-approve -target=runpod_pod.trainer 2>&1 || \
    tf destroy -auto-approve -lock=false -target=runpod_pod.trainer
}

get_pod_ids() {
  tf output -json pod_ids 2>/dev/null | python3 -c "
import json, sys
try:
    ids = json.load(sys.stdin)
except Exception:
    ids = []
for pod_id in ids:
    if pod_id and pod_id != 'null':
        print(pod_id)
"
}

get_pod_costs() {
  tf output -json pod_cost_per_hour 2>/dev/null | python3 -c "
import json, sys
try:
    costs = json.load(sys.stdin)
except Exception:
    costs = []
for cost in costs:
    if cost is not None:
        print(float(cost))
"
}

cost_exceeds_limit() {
  python3 - "$MAX_COST_PER_HOUR" "$1" <<'PY'
import sys
limit = float(sys.argv[1])
cost = float(sys.argv[2])
raise SystemExit(0 if cost > limit else 1)
PY
}

get_pod_connection() {
  local pod_id="$1"
  python3 - "$pod_id" "${RUNPOD_API_KEY}" <<'PY'
import json, sys, urllib.request
pod_id, api_key = sys.argv[1], sys.argv[2]
try:
    req = urllib.request.Request(
        f"https://rest.runpod.io/v1/pods/{pod_id}",
        headers={"Authorization": "Bearer " + api_key},
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        pod = json.loads(resp.read())
    ip = pod.get("publicIp") or ""
    mappings = pod.get("portMappings") or {}
    port = str(mappings.get("22") or "")
    print(ip)
    print(port)
except Exception as e:
    print(f"Pod connection lookup failed: {e}", file=sys.stderr)
    print("")
    print("")
PY
}

_ssh_opts() {
  local port="$1"
  echo "-i ${SSH_KEY} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes -p ${port}"
}

wait_for_ssh() {
  local pod_id="$1"
  local elapsed=0 ip="" port=""

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "1.2.3.4 22"
    return 0
  fi

  echo "Waiting for pod ${pod_id} to get public IP and SSH port (timeout: ${SSH_TIMEOUT}s)..."
  while true; do
    local conn
    conn="$(get_pod_connection "$pod_id")"
    ip="$(echo "$conn" | head -1)"
    port="$(echo "$conn" | tail -1)"

    if [[ -n "$ip" && -n "$port" ]]; then
      echo "Pod reachable at ${ip}:${port}"
      if ssh -q \
          -i "$SSH_KEY" \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=5 \
          -o BatchMode=yes \
          -p "$port" \
          "${SSH_USER}@${ip}" \
          exit 2>/dev/null; then
        echo "SSH ready: ${SSH_USER}@${ip}:${port}"
        echo "$ip $port"
        return 0
      fi
    fi

    if ((elapsed >= SSH_TIMEOUT)); then
      echo "ERROR: SSH not ready after ${SSH_TIMEOUT}s (last: ${ip:-?}:${port:-?})"
      return 1
    fi
    sleep 15
    ((elapsed += 15))
    echo "Waiting... ip=${ip:-?} port=${port:-?} (${elapsed}s elapsed)"
  done
}

sync_code() {
  local ip="$1" port="$2" remote_dir="$3"
  echo "rsyncing repo to ${SSH_USER}@${ip}:${port}:${remote_dir} ..."
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] rsync ${REPO_ROOT}/ ${SSH_USER}@${ip}:${remote_dir}/"
    return 0
  fi

  local opts
  opts="$(_ssh_opts "$port")"
  # shellcheck disable=SC2086
  ssh -q $opts "${SSH_USER}@${ip}" \
    "command -v rsync &>/dev/null || (apt-get update -qq && apt-get install -y -qq rsync)"
  # shellcheck disable=SC2086
  ssh -q $opts "${SSH_USER}@${ip}" "mkdir -p ${remote_dir}"
  # shellcheck disable=SC2086
  rsync -az --no-owner --no-group --progress \
    --include='data/test/*.jpg' \
    --include='data/test/*.jpeg' \
    --include='data/test/*.png' \
    --filter=':- .gitignore' \
    --exclude '.git' \
    --exclude '__pycache__' \
    --exclude '*.pyc' \
    --exclude '.venv' \
    --exclude 'node_modules' \
    --exclude 'infra/runpod/.terraform' \
    --exclude 'infra/runpod/terraform.tfstate*' \
    --exclude 'infra/runpod/tfplan' \
    --exclude 'data/train' \
    -e "ssh $opts" \
    "${REPO_ROOT}/" \
    "${SSH_USER}@${ip}:${remote_dir}/"
}

fetch_remote_predictions() {
  local model="$1" ip="$2" port="$3" remote_dir="$4"
  local safe_model local_dir opts
  safe_model="$(sanitize_name "$model")"
  local_dir="${LOG_DIR}/predictions/${RUN_ID}/${safe_model}"
  echo "Fetching predictions for model=${model} to ${local_dir}"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] rsync ${SSH_USER}@${ip}:${remote_dir}/data/predictions/${model}/ ${local_dir}/"
    return 0
  fi
  mkdir -p "$local_dir"
  opts="$(_ssh_opts "$port")"
  # shellcheck disable=SC2086
  rsync -az --no-owner --no-group \
    -e "ssh $opts" \
    "${SSH_USER}@${ip}:${remote_dir}/data/predictions/${model}/" \
    "${local_dir}/" || echo "WARNING: prediction fetch failed for model=${model}"
}

run_remote_tests() {
  local model="$1" ip="$2" port="$3" remote_dir="$4"
  echo "Running $(basename "$TEST_SCRIPT") for model=${model} on ${SSH_USER}@${ip}:${port}"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] STRG_TEST_MODEL=${model} WORKSPACE=${remote_dir} bash $(basename "$TEST_SCRIPT")"
    return 0
  fi

  local opts remote_exports env_name env_value quoted_model quoted_workspace
  opts="$(_ssh_opts "$port")"
  printf -v quoted_model '%q' "$model"
  printf -v quoted_workspace '%q' "$remote_dir"
  remote_exports="export STRG_TEST_MODEL=${quoted_model}; export WORKSPACE=${quoted_workspace};"

  for env_name in WANDB_API_KEY STRG_TEST_IMAGES STRG_GROUND_TRUTH STRG_PREDICTIONS STRG_QWEN_MIN_VISUAL_TOKENS STRG_QWEN_MAX_VISUAL_TOKENS STRG_QWEN_MAX_NEW_TOKENS STRG_FINETUNE_MODEL STRG_EPOCHS STRG_TRAIN_DIR STRG_VAL_DIR STRG_OUTPUT_DIR; do
    env_value="${!env_name:-}"
    if [[ -n "$env_value" ]]; then
      printf -v remote_exports "%s export %s=%q;" "$remote_exports" "$env_name" "$env_value"
    fi
  done

  # shellcheck disable=SC2086
  ssh -q $opts \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=120 \
    "${SSH_USER}@${ip}" \
    "${remote_exports} cd ${quoted_workspace} && bash -s" < "$TEST_SCRIPT"
}

run_model_job() {
  local model="$1" pod_id="$2" log_file="$3"
  local safe_model remote_dir conn ip port
  safe_model="$(sanitize_name "$model")"
  remote_dir="${REMOTE_BASE}/${RUN_ID}/${safe_model}"

  {
    echo "==================================================================="
    echo "strg matrix model job — $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  model:      ${model}"
    echo "  pod_id:     ${pod_id}"
    echo "  workspace:  ${remote_dir}"
    echo "==================================================================="

    conn="$(wait_for_ssh "$pod_id")"
    ip="$(echo "$conn" | tail -1 | awk '{print $1}')"
    port="$(echo "$conn" | tail -1 | awk '{print $2}')"
    if [[ -z "$ip" || -z "$port" ]]; then
      echo "ERROR: Could not resolve SSH connection for pod ${pod_id}"
      return 1
    fi

    if [[ $NO_SYNC -eq 0 ]]; then
      sync_code "$ip" "$port" "$remote_dir"
    fi

    run_remote_tests "$model" "$ip" "$port" "$remote_dir"
    status=$?
    fetch_remote_predictions "$model" "$ip" "$port" "$remote_dir"
    echo "==================================================================="
    echo "strg matrix model job complete — $(date '+%Y-%m-%d %H:%M:%S') — exit=${status}"
    echo "==================================================================="
    return "$status"
  } > "$log_file" 2>&1
}

summarize_log() {
  local model="$1" log_file="$2" status="$3"
  local verdict metrics
  verdict="$(grep -E 'OVERALL: ' "$log_file" | tail -1 | sed 's/^[[:space:]]*//' || true)"
  metrics="$(python3 - "$log_file" <<'PY'
import json, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(errors='replace')
blocks = []
start = 0
while True:
    b = text.find('{', start)
    if b == -1:
        break
    depth = 0
    in_str = False
    esc = False
    for i in range(b, len(text)):
        ch = text[i]
        if in_str:
            if esc:
                esc = False
            elif ch == '\\':
                esc = True
            elif ch == '"':
                in_str = False
        else:
            if ch == '"':
                in_str = True
            elif ch == '{':
                depth += 1
            elif ch == '}':
                depth -= 1
                if depth == 0:
                    candidate = text[b:i+1]
                    try:
                        obj = json.loads(candidate)
                    except Exception:
                        pass
                    else:
                        if 'avg_cer' in obj and 'macro_field_accuracy' in obj:
                            blocks.append(obj)
                    start = i + 1
                    break
    else:
        break
if blocks:
    obj = blocks[-1]
    print(f"CER={obj.get('avg_cer'):.3f} ACC={obj.get('macro_field_accuracy'):.3f} photos={obj.get('evaluated_photos')}/{obj.get('ground_truth_photos')}")
PY
)"
  printf '  %-12s exit=%-3s %-45s %s\n' "$model" "$status" "${metrics:-metrics=?}" "${verdict:-verdict=?}"
  printf '    log: %s\n' "$log_file"
}

run_batch() {
  local batch_index="$1"
  shift
  local -a batch_models=("$@")
  local batch_count="${#batch_models[@]}"
  local -a pod_ids=()
  local -a pod_costs=()
  local -a pids=()
  local -a log_files=()
  local -a status_files=()
  local -a statuses=()
  local batch_failed=0
  local status_dir="${LOG_DIR}/.matrix-${RUN_ID}-batch-${batch_index}"

  info "━━━ Matrix batch ${batch_index}: ${batch_models[*]} ━━━━━━━━━━━━━━━━━"

  if ! provision_batch "$batch_count"; then
    err "Provision failed for batch ${batch_index}."
    teardown_batch || warn "Teardown after failed provision also failed."
    LAST_BATCH_STATUS=1
    return 0
  fi

  cleanup_needed=1
  _cleanup_batch() {
    if [[ $cleanup_needed -eq 1 ]]; then
      warn "Emergency cleanup: tearing down matrix batch pods..."
      teardown_batch || warn "Teardown failed — check RunPod console for orphaned pods."
      cleanup_needed=0
    fi
  }
  trap _cleanup_batch EXIT

  if [[ $DRY_RUN -eq 1 ]]; then
    local i
    for ((i=0; i<batch_count; i++)); do
      pod_ids+=("dry-run-pod-$((i + 1))")
    done
  else
    while IFS= read -r pod_id; do
      [[ -n "$pod_id" ]] && pod_ids+=("$pod_id")
    done < <(get_pod_ids)
  fi

  if [[ "${#pod_ids[@]}" -ne "$batch_count" ]]; then
    err "Expected ${batch_count} pod IDs, got ${#pod_ids[@]}. Tearing down."
    teardown_batch || warn "Teardown failed after pod ID mismatch."
    cleanup_needed=0
    trap - EXIT
    LAST_BATCH_STATUS=1
    return 0
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    local i
    for ((i=0; i<batch_count; i++)); do
      pod_costs+=("0")
    done
  else
    while IFS= read -r pod_cost; do
      [[ -n "$pod_cost" ]] && pod_costs+=("$pod_cost")
    done < <(get_pod_costs)
  fi
  for pod_cost in "${pod_costs[@]}"; do
    if cost_exceeds_limit "$pod_cost"; then
      err "Refusing to run pod costing ${pod_cost}/hr above limit ${MAX_COST_PER_HOUR}/hr. Tearing down."
      teardown_batch || warn "Teardown failed after cost guard."
      cleanup_needed=0
      trap - EXIT
      LAST_BATCH_STATUS=1
      return 0
    fi
  done

  mkdir -p "$status_dir"

  local i model safe_model log_file status_file
  for ((i=0; i<batch_count; i++)); do
    model="${batch_models[$i]}"
    safe_model="$(sanitize_name "$model")"
    log_file="${LOG_DIR}/matrix-${RUN_ID}-${safe_model}.log"
    status_file="${status_dir}/${safe_model}.status"
    rm -f "$status_file"
    log_files+=("$log_file")
    status_files+=("$status_file")
    statuses+=("")
    info "Launching model=${model} on pod=${pod_ids[$i]} (log: ${log_file})"
    (
      set +e
      run_model_job "$model" "${pod_ids[$i]}" "$log_file"
      code=$?
      echo "$code" > "$status_file"
      exit "$code"
    ) &
    pids+=("$!")
  done

  local start_ts now elapsed completed status
  start_ts="$(date +%s)"
  while true; do
    completed=0
    for status_file in "${status_files[@]}"; do
      [[ -f "$status_file" ]] && completed=$((completed + 1))
    done
    [[ "$completed" -eq "$batch_count" ]] && break

    if [[ "$BATCH_TIMEOUT" -gt 0 ]]; then
      now="$(date +%s)"
      elapsed=$((now - start_ts))
      if [[ "$elapsed" -ge "$BATCH_TIMEOUT" ]]; then
        err "Batch ${batch_index} exceeded ${BATCH_TIMEOUT}s. Killing local SSH jobs and tearing down pods."
        for pid in "${pids[@]}"; do
          kill "$pid" 2>/dev/null || true
        done
        for status_file in "${status_files[@]}"; do
          [[ -f "$status_file" ]] || echo "124" > "$status_file"
        done
        batch_failed=124
        break
      fi
    fi
    sleep 2
  done

  for ((i=0; i<batch_count; i++)); do
    set +e
    wait "${pids[$i]}"
    set -e
    status="$(cat "${status_files[$i]}" 2>/dev/null || echo 1)"
    statuses[$i]="$status"
    if [[ "$status" -ne 0 ]]; then
      batch_failed=1
    fi
  done

  echo ""
  echo "=== MATRIX BATCH ${batch_index} SUMMARY ==="
  for ((i=0; i<batch_count; i++)); do
    summarize_log "${batch_models[$i]}" "${log_files[$i]}" "${statuses[$i]}"
  done

  if ! teardown_batch; then
    err "Teardown failed for batch ${batch_index}. Stopping to avoid orphaned pods."
    cleanup_needed=0
    trap - EXIT
    return 2
  fi
  cleanup_needed=0
  trap - EXIT

  info "━━━ Matrix batch ${batch_index} done ━━━━━━━━━━━━━━━━━"
  LAST_BATCH_STATUS="$batch_failed"
  return 0
}

main() {
  check_prereqs

  if [[ $DRY_RUN -eq 1 ]]; then
    warn "DRY RUN MODE: no pods will be provisioned."
  fi

  info "Run ID: ${RUN_ID}"
  info "Models: ${MODELS[*]}"
  info "Max parallel pods/models: ${MAX_PARALLEL}"
  info "Max pod cost per hour: ${MAX_COST_PER_HOUR}"
  info "GPU fallback list: ${GPU_TYPE_IDS_CSV}"
  [[ -n "$CLOUD_TYPE" ]] && info "Cloud type override: ${CLOUD_TYPE}"
  info "Batch timeout: ${BATCH_TIMEOUT}s"
  info "Logs: ${LOG_DIR}"

  local total="${#MODELS[@]}"
  local start=0 batch_index=1 overall_exit=0
  while [[ "$start" -lt "$total" ]]; do
    local -a batch=()
    local i end
    end=$((start + MAX_PARALLEL))
    [[ "$end" -gt "$total" ]] && end="$total"
    for ((i=start; i<end; i++)); do
      batch+=("${MODELS[$i]}")
    done

    run_batch "$batch_index" "${batch[@]}"
    batch_status="$LAST_BATCH_STATUS"
    if [[ "$batch_status" -eq 2 ]]; then
      exit 2
    fi
    if [[ "$batch_status" -ne 0 ]]; then
      overall_exit=1
    fi

    start="$end"
    batch_index=$((batch_index + 1))
  done

  if [[ "$overall_exit" -eq 0 ]]; then
    info "All matrix model jobs passed."
  else
    err "Matrix completed with one or more model failures."
  fi
  exit "$overall_exit"
}

main
