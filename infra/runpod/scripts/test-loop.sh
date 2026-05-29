#!/usr/bin/env bash
# test-loop.sh - RunPod regression test loop.
#
# Each iteration:
#   1. terraform apply (pod_count=1) with your SSH key injected
#   2. Wait for pod IP and SSH port via RunPod REST API (rest.runpod.io/v1/pods/<id>)
#   3. Wait for SSH to be ready on the NAT-mapped port
#   4. rsync repo to pod
#   5. Run test script on pod
#   6. terraform destroy pod (always, even on test failure)
#
# SSH connection: root@<publicIp> -p <portMappings['22']>
# Port mapping is read from RunPod REST API — no proxy needed.
#
# Usage: scripts/test-loop.sh [OPTIONS]
#
# Options:
#   --iterations N          Number of iterations (default: 1; 0 = loop forever)
#   --ssh-key PATH          SSH private key (default: auto-detected from ~/.ssh/)
#   --ssh-user USER         SSH user (default: root)
#   --test-script PATH      Script to run on pod (default: scripts/pod-tests.sh)
#   --remote-dir PATH       Remote working directory (default: /workspace/strg)
#   --no-sync               Skip rsync step
#   --ssh-timeout SECS      Max wait for IP+port assignment and SSH (default: 300)
#   --iteration-timeout SECS  Hard wall-clock limit per full iteration (default: 0 = none)
#                           On breach: forces pod teardown and exits with code 124.
#   --log-file PATH         Tee all stderr output to this file as well
#   --dry-run               Print what would run, no actual provisioning
#   -h, --help              Show this help
#
# Prerequisites:
#   export TF_VAR_ssh_public_key="$(cat ~/.ssh/id_ed25519.pub)"
#   export RUNPOD_API_KEY="<your-key>"   # also used by Terraform provider

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$TF_DIR/../.." && pwd)"

# ── Defaults ──────────────────────────────────────────────────────────────────
ITERATIONS=1
# Auto-detect SSH key (prefer ed25519)
SSH_KEY=""
for _k in "${HOME}/.ssh/id_ed25519" "${HOME}/.ssh/id_rsa" "${HOME}/.ssh/id_ecdsa"; do
  if [[ -f "$_k" ]]; then SSH_KEY="$_k"; break; fi
done
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_rsa}"
SSH_USER="root"
TEST_SCRIPT="$SCRIPT_DIR/pod-tests.sh"
REMOTE_DIR="/workspace/strg"
NO_SYNC=0
SSH_TIMEOUT=600
ITERATION_TIMEOUT=0   # 0 = no hard limit
LOG_FILE=""
DRY_RUN=0

# ── Arg parsing ───────────────────────────────────────────────────────────────
usage() {
  cat <<'USAGE'
Usage: scripts/test-loop.sh [OPTIONS]

Each iteration: terraform apply → wait for IP+port (REST API) → SSH → rsync → run tests → terraform destroy pod

SSH: root@<publicIp> -p <portMappings['22']>   (NAT port from RunPod REST API)

Options:
  --iterations N          Iterations to run (default: 1; 0 = forever)
  --ssh-key PATH          SSH private key (default: auto-detected)
  --ssh-user USER         SSH user on pod (default: root)
  --test-script PATH      Script to run on pod (default: scripts/pod-tests.sh)
  --remote-dir PATH       Remote working directory (default: /workspace/strg)
  --no-sync               Skip rsync step
  --ssh-timeout SECS      Max wait for IP+port assignment and SSH (default: 300)
  --iteration-timeout SECS  Hard limit per iteration; forces teardown + exit 124 (default: 0 = none)
  --log-file PATH         Tee all output to this file
  --dry-run               Print steps without provisioning
  -h, --help              Show this help

Prerequisites:
  export TF_VAR_ssh_public_key="$(cat ~/.ssh/id_ed25519.pub)"
  export RUNPOD_API_KEY="<your-key>"
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iterations)          ITERATIONS="$2"; shift 2 ;;
    --ssh-key)             SSH_KEY="$2"; shift 2 ;;
    --ssh-user)            SSH_USER="$2"; shift 2 ;;
    --test-script)         TEST_SCRIPT="$2"; shift 2 ;;
    --remote-dir)          REMOTE_DIR="$2"; shift 2 ;;
    --no-sync)             NO_SYNC=1; shift ;;
    --ssh-timeout)         SSH_TIMEOUT="$2"; shift 2 ;;
    --iteration-timeout)   ITERATION_TIMEOUT="$2"; shift 2 ;;
    --log-file)            LOG_FILE="$2"; shift 2 ;;
    --dry-run)             DRY_RUN=1; shift ;;
    -h|--help)             usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ── Log file tee ──────────────────────────────────────────────────────────────
if [[ -n "$LOG_FILE" ]]; then
  mkdir -p "$(dirname "$LOG_FILE")"
  # Redirect stderr through tee to LOG_FILE; stdout stays clean for data
  exec 2> >(tee -a "$LOG_FILE" >&2)
fi

# ── Logging ───────────────────────────────────────────────────────────────────
# All log output goes to stderr so stdout is reserved for data (e.g. pod IP).
log()  { echo "[$(date '+%H:%M:%S')] $*" >&2; }
info() { log "INFO  $*"; }
warn() { log "WARN  $*"; }
err()  { log "ERROR $*"; }

# ── Watchdog (hard per-iteration timeout) ─────────────────────────────────────
_WATCHDOG_PID=""
_ITER_LABEL=""

_start_watchdog() {
  _ITER_LABEL="$1"
  [[ $ITERATION_TIMEOUT -le 0 || $DRY_RUN -eq 1 ]] && return 0
  local main_pid=$$
  (
    sleep "$ITERATION_TIMEOUT"
    echo "[$(date '+%H:%M:%S')] WARN  HARD TIMEOUT: iteration ${_ITER_LABEL} exceeded ${ITERATION_TIMEOUT}s. Forcing teardown." >&2
    # Best-effort teardown from watchdog. Use -lock=false so the main
    # process teardown (if it runs after) won't collide on the state lock.
    terraform -chdir="$TF_DIR" destroy -auto-approve -lock=false \
      -target=runpod_pod.trainer >/dev/null 2>&1 || true
    # Signal main process to exit 124
    kill -TERM "$main_pid" 2>/dev/null || true
  ) &
  _WATCHDOG_PID=$!
  info "Watchdog started (pid ${_WATCHDOG_PID}, timeout ${ITERATION_TIMEOUT}s)."
}

_stop_watchdog() {
  if [[ -n "${_WATCHDOG_PID:-}" ]]; then
    kill "$_WATCHDOG_PID" 2>/dev/null || true
    wait "$_WATCHDOG_PID" 2>/dev/null || true
    _WATCHDOG_PID=""
  fi
}

# TERM handler: invoked when watchdog fires
_handle_sigterm() {
  err "SIGTERM received (watchdog fired). Iteration ${_ITER_LABEL} timed out (${ITERATION_TIMEOUT}s)."
  _WATCHDOG_PID=""  # already done
  exit 124
}
trap '_handle_sigterm' TERM

# ── Prerequisites ─────────────────────────────────────────────────────────────
check_prereqs() {
  local missing=0
  for cmd in terraform ssh rsync python3; do
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

  # Resolve PUBLIC_KEY for SSH injection into pods
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
    err "RUNPOD_API_KEY is not set (required for Terraform provider and user ID lookup)."
    exit 1
  fi
}

# ── Terraform helpers ─────────────────────────────────────────────────────────
tf() {
  terraform -chdir="$TF_DIR" "$@"
}

provision() {
  info "Provisioning pod (terraform apply pod_count=1)..."
  if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run] terraform apply -auto-approve -var pod_count=1"
    return 0
  fi
  tf apply -auto-approve -var "pod_count=1"
}

teardown_pod() {
  info "Tearing down pod..."
  if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run] terraform destroy -auto-approve -target=runpod_pod.trainer"
    return 0
  fi
  # First attempt with locking; retry with -lock=false if the watchdog
  # process is concurrently holding the state lock.
  tf destroy -auto-approve -target=runpod_pod.trainer 2>&1 || \
    tf destroy -auto-approve -lock=false -target=runpod_pod.trainer
}

get_pod_id() {
  tf output -json pod_ids 2>/dev/null \
    | python3 -c "
import json, sys
try:
    ids = json.load(sys.stdin)
    pid = ids[0] if ids else ''
    print(pid if pid and pid != 'null' else '', end='')
except Exception:
    print('', end='')
"
}

# Query RunPod REST API for pod's publicIp and SSH port mapping.
# REST API: GET https://rest.runpod.io/v1/pods/<id>
# Returns two lines: <ip> <port>  (empty strings if not yet assigned)
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

# Wait for pod to get a public IP and SSH port via REST API,
# then wait for SSH to actually accept connections.
wait_for_ssh() {
  local pod_id="$1"
  if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run] wait for SSH on pod ${pod_id}"
    # Export fake values for dry-run callers
    POD_IP="1.2.3.4"
    POD_SSH_PORT="22"
    return 0
  fi

  local elapsed=0
  local ip="" port=""
  info "Waiting for pod ${pod_id} to get public IP and SSH port (timeout: ${SSH_TIMEOUT}s)..."

  while true; do
    local conn
    conn="$(get_pod_connection "$pod_id")"
    ip="$(echo "$conn" | head -1)"
    port="$(echo "$conn" | tail -1)"

    if [[ -n "$ip" && -n "$port" ]]; then
      info "Pod reachable at ${ip}:${port}"
      # Try actual SSH connection
      if ssh -q \
          -i "$SSH_KEY" \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=5 \
          -o BatchMode=yes \
          -p "$port" \
          "${SSH_USER}@${ip}" \
          exit 2>/dev/null; then
        info "SSH ready: ${SSH_USER}@${ip}:${port}"
        export POD_IP="$ip"
        export POD_SSH_PORT="$port"
        return 0
      fi
    fi

    if ((elapsed >= SSH_TIMEOUT)); then
      err "SSH not ready after ${SSH_TIMEOUT}s (last: ${ip}:${port})"
      return 1
    fi
    sleep 15
    ((elapsed += 15))
    info "  Waiting... ip=${ip:-?} port=${port:-?} (${elapsed}s elapsed)"
  done
}

# SSH options shared across sync/run calls
_ssh_opts() {
  local port="$1"
  echo "-i ${SSH_KEY} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes -p ${port}"
}

# ── Code sync ─────────────────────────────────────────────────────────────────
sync_code() {
  local ip="$1" port="$2"
  info "rsyncing repo to ${SSH_USER}@${ip}:${port}:${REMOTE_DIR} ..."
  if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run] rsync ${REPO_ROOT}/ ${SSH_USER}@${POD_IP}:${REMOTE_DIR}/"
    return 0
  fi
  local opts
  opts="$(_ssh_opts "$port")"
  # Ensure rsync is available on the pod (PyTorch images don't include it)
  # shellcheck disable=SC2086
  ssh -q $opts "${SSH_USER}@${ip}" \
    "command -v rsync &>/dev/null || (apt-get update -qq && apt-get install -y -qq rsync)"
  # shellcheck disable=SC2086
  ssh -q $opts "${SSH_USER}@${ip}" "mkdir -p ${REMOTE_DIR}"
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
    "${SSH_USER}@${ip}:${REMOTE_DIR}/"
}

# ── Test execution ─────────────────────────────────────────────────────────────
run_tests() {
  local ip="$1" port="$2"
  info "Running test script on ${SSH_USER}@${ip}:${port}: $(basename "$TEST_SCRIPT")"
  local opts
  opts="$(_ssh_opts "$port")"
  # shellcheck disable=SC2086
  # Redirect stdout→stderr so all pod output lands in the log file
  # (test-loop.sh captures stderr; stdout was discarded via launch redirect)
  # Forward selected run-time env vars so callers can choose the model/dataset
  # without changing Terraform vars or editing the remote script.
  local remote_exports=""
  local env_name env_value
  for env_name in WANDB_API_KEY STRG_TEST_MODEL STRG_TEST_IMAGES STRG_GROUND_TRUTH STRG_PREDICTIONS STRG_QWEN_MIN_VISUAL_TOKENS STRG_QWEN_MAX_VISUAL_TOKENS STRG_QWEN_MAX_NEW_TOKENS; do
    env_value="${!env_name:-}"
    if [[ -n "$env_value" ]]; then
      printf -v remote_exports "%s export %s=%q;" "$remote_exports" "$env_name" "$env_value"
    fi
  done
  if [[ $DRY_RUN -eq 1 ]]; then
    [[ -n "$remote_exports" ]] && info "[dry-run] remote env:${remote_exports}"
    info "[dry-run] ssh ${SSH_USER}@${POD_IP}:${POD_SSH_PORT} ${remote_exports} bash < ${TEST_SCRIPT}"
    return 0
  fi
  ssh -q $opts \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=120 \
    "${SSH_USER}@${ip}" \
    "${remote_exports} cd ${REMOTE_DIR} && bash -s" < "$TEST_SCRIPT" >&2
}

# ── Single iteration ──────────────────────────────────────────────────────────
run_once() {
  local iter="$1"
  local test_exit=0

  info "━━━ Iteration ${iter} start $(date '+%Y-%m-%d %H:%M:%S') ━━━━━━━━━━━━━━━━━"

  # 1. Provision
  if ! provision; then
    err "Provision failed on iteration ${iter}. Skipping teardown."
    return 1
  fi

  # Start hard-timeout watchdog after successful provision
  _start_watchdog "$iter"

  # From here on, teardown must run even if later steps fail
  local cleanup_needed=1

  _teardown_on_exit() {
    if [[ $cleanup_needed -eq 1 ]]; then
      warn "Emergency cleanup: tearing down pod..."
      _stop_watchdog
      teardown_pod || warn "Teardown failed — check RunPod console for orphaned pods."
      cleanup_needed=0
    fi
  }
  trap _teardown_on_exit EXIT

  # 2. Get pod ID from terraform output
  local pod_id=""
  POD_IP=""
  POD_SSH_PORT=""
  if [[ $DRY_RUN -eq 1 ]]; then
    pod_id="dry-run-pod"
    info "[dry-run] pod ID: ${pod_id}"
  else
    pod_id="$(get_pod_id)"
    if [[ -z "$pod_id" ]]; then
      err "Could not get pod ID from terraform output. Tearing down."
      _stop_watchdog
      teardown_pod || { err "Teardown also failed. Stopping loop."; cleanup_needed=0; return 2; }
      cleanup_needed=0
      trap - EXIT
      return 1
    fi
    info "Pod ID: ${pod_id}"
  fi

  # 3. Wait for SSH (polls REST API for ip+port, then tests connection)
  if ! wait_for_ssh "$pod_id"; then
    err "SSH not reachable for pod ${pod_id} — pod may lack public IP. Tearing down and reprovisioning."
    _stop_watchdog
    teardown_pod || { err "Teardown also failed. Stopping loop."; cleanup_needed=0; return 2; }
    cleanup_needed=0
    trap - EXIT
    # Return 3 = infra/no-IP failure: caller should reprovision, not count as test iteration
    return 3
  fi

  # 4. Sync code
  if [[ $NO_SYNC -eq 0 ]]; then
    if ! sync_code "$POD_IP" "$POD_SSH_PORT"; then
      err "rsync failed. Tearing down."
      _stop_watchdog
      teardown_pod || { err "Teardown also failed. Stopping loop."; cleanup_needed=0; return 2; }
      cleanup_needed=0
      trap - EXIT
      return 1
    fi
  fi

  # 5. Run tests (capture exit code; always proceed to teardown)
  run_tests "$POD_IP" "$POD_SSH_PORT" || test_exit=$?
  if [[ $test_exit -ne 0 ]]; then
    warn "Tests FAILED on iteration ${iter} (exit ${test_exit})."
  else
    info "Tests PASSED on iteration ${iter}."
  fi

  # 6. Stop watchdog + teardown
  _stop_watchdog
  if ! teardown_pod; then
    err "Teardown failed on iteration ${iter}. Stopping loop to avoid orphaned pods."
    cleanup_needed=0
    trap - EXIT
    return 2
  fi
  cleanup_needed=0
  trap - EXIT

  info "━━━ Iteration ${iter} done $(date '+%Y-%m-%d %H:%M:%S') ━━━━━━━━━━━━━━━━━━"
  return $test_exit
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  check_prereqs

  if [[ $DRY_RUN -eq 1 ]]; then
    warn "DRY RUN MODE: no pods will be provisioned."
  fi

  if [[ $ITERATION_TIMEOUT -gt 0 ]]; then
    info "Hard iteration timeout: ${ITERATION_TIMEOUT}s per iteration."
  fi

  local iter=1
  local last_exit=0
  local loop_exit=0

  local reprovision_attempts=0
  while true; do
    run_once "$iter"
    last_exit=$?

    if [[ $last_exit -eq 124 ]]; then
      err "Iteration ${iter} timed out. Stopping loop."
      loop_exit=124
      break
    fi

    if [[ $last_exit -eq 2 ]]; then
      err "Stopping loop due to teardown failure."
      loop_exit=1
      break
    fi

    if [[ $last_exit -eq 3 ]]; then
      reprovision_attempts=$((reprovision_attempts + 1))
      if [[ $reprovision_attempts -ge 5 ]]; then
        err "Failed to get a pod with public IP after ${reprovision_attempts} attempts. Stopping."
        loop_exit=1
        break
      fi
      warn "Pod had no public IP (attempt ${reprovision_attempts}/5). Reprovisioning..."
      sleep 10
      continue  # retry same iter without incrementing
    fi

    reprovision_attempts=0
    [[ $last_exit -ne 0 ]] && loop_exit=$last_exit

    if [[ $ITERATIONS -ne 0 ]] && [[ $iter -ge $ITERATIONS ]]; then
      break
    fi

    ((iter++))
    info "Pausing 5s before next iteration..."
    sleep 5
  done

  if [[ $loop_exit -eq 0 ]]; then
    info "All iterations completed successfully."
  else
    err "Loop finished with failures (exit $loop_exit)."
  fi
  exit $loop_exit
}

main
