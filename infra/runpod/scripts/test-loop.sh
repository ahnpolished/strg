#!/usr/bin/env bash
# test-loop.sh - RunPod regression test loop.
#
# Each iteration:
#   1. terraform apply (pod_count=1) with your SSH key injected
#   2. Wait for pod IP assignment
#   3. Wait for SSH to become reachable
#   4. rsync repo to pod
#   5. Run test script on pod
#   6. terraform destroy pod (always, even on test failure)
#
# Usage: scripts/test-loop.sh [OPTIONS]
#
# Options:
#   --iterations N          Number of iterations (default: 1; 0 = loop forever)
#   --ssh-key PATH          SSH private key (default: auto-detected from ~/.ssh/)
#   --ssh-user USER         SSH user (default: root)
#   --ssh-port PORT         SSH port (default: 22)
#   --test-script PATH      Script to run on pod (default: scripts/pod-tests.sh)
#   --remote-dir PATH       Remote working directory (default: /workspace/strg)
#   --no-sync               Skip rsync step
#   --ip-timeout SECS       Max wait for IP assignment (default: 180)
#   --ssh-timeout SECS      Max wait for SSH readiness (default: 300)
#   --iteration-timeout SECS  Hard wall-clock limit per full iteration (default: 0 = none)
#                           On breach: forces pod teardown and exits with code 124.
#   --log-file PATH         Tee all stderr output to this file as well
#   --dry-run               Print what would run, no actual provisioning
#   -h, --help              Show this help
#
# Prerequisite: export TF_VAR_ssh_public_key="$(cat ~/.ssh/id_ed25519.pub)"

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
SSH_PORT=22
TEST_SCRIPT="$SCRIPT_DIR/pod-tests.sh"
REMOTE_DIR="/workspace/strg"
NO_SYNC=0
IP_TIMEOUT=180
SSH_TIMEOUT=300
ITERATION_TIMEOUT=0   # 0 = no hard limit
LOG_FILE=""
DRY_RUN=0

# ── Arg parsing ───────────────────────────────────────────────────────────────
usage() {
  cat <<'USAGE'
Usage: scripts/test-loop.sh [OPTIONS]

Each iteration: terraform apply → wait for SSH → rsync repo → run test script → terraform destroy pod

Options:
  --iterations N          Iterations to run (default: 1; 0 = forever)
  --ssh-key PATH          SSH private key (default: auto-detected)
  --ssh-user USER         SSH user (default: root)
  --ssh-port PORT         SSH port (default: 22)
  --test-script PATH      Script to run on pod (default: scripts/pod-tests.sh)
  --remote-dir PATH       Remote working directory (default: /workspace/strg)
  --no-sync               Skip rsync step
  --ip-timeout SECS       Max wait for IP assignment (default: 180)
  --ssh-timeout SECS      Max wait for SSH readiness (default: 300)
  --iteration-timeout SECS  Hard limit per iteration; forces teardown + exit 124 (default: 0 = none)
  --log-file PATH         Tee all output to this file
  --dry-run               Print steps without provisioning
  -h, --help              Show this help

Prerequisite: export TF_VAR_ssh_public_key="$(cat ~/.ssh/id_ed25519.pub)"
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iterations)          ITERATIONS="$2"; shift 2 ;;
    --ssh-key)             SSH_KEY="$2"; shift 2 ;;
    --ssh-user)            SSH_USER="$2"; shift 2 ;;
    --ssh-port)            SSH_PORT="$2"; shift 2 ;;
    --test-script)         TEST_SCRIPT="$2"; shift 2 ;;
    --remote-dir)          REMOTE_DIR="$2"; shift 2 ;;
    --no-sync)             NO_SYNC=1; shift ;;
    --ip-timeout)          IP_TIMEOUT="$2"; shift 2 ;;
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
    # Best-effort teardown from watchdog (may race with main, that's OK)
    terraform -chdir="$TF_DIR" destroy -auto-approve -target=runpod_pod.trainer \
      >/dev/null 2>&1 || true
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
  for cmd in terraform ssh rsync python3 nc; do
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
  tf destroy -auto-approve -target=runpod_pod.trainer
}

get_pod_ip() {
  tf output -json pod_public_ips 2>/dev/null \
    | python3 -c "
import json, sys
try:
    ips = json.load(sys.stdin)
    ip = ips[0] if ips else ''
    print(ip if ip and ip != 'null' else '', end='')
except Exception:
    print('', end='')
"
}

refresh_state() {
  tf apply -refresh-only -auto-approve -var "pod_count=1" >/dev/null 2>&1 || true
}

wait_for_ip() {
  if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run] wait for IP → returning 1.2.3.4"
    echo "1.2.3.4"
    return 0
  fi
  local elapsed=0
  local ip=""
  info "Waiting for pod IP assignment (timeout: ${IP_TIMEOUT}s)..."
  while true; do
    ip="$(get_pod_ip)"
    if [[ -n "$ip" ]]; then
      info "Pod IP assigned: $ip"
      echo "$ip"
      return 0
    fi
    if ((elapsed >= IP_TIMEOUT)); then
      err "IP not assigned after ${IP_TIMEOUT}s."
      return 1
    fi
    sleep 10
    ((elapsed += 10))
    info "  Still waiting for IP... (${elapsed}s elapsed)"
    refresh_state
  done
}

wait_for_ssh() {
  local ip="$1"
  if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run] wait for SSH on ${ip}:${SSH_PORT}"
    return 0
  fi
  local elapsed=0
  info "Waiting for SSH on ${ip}:${SSH_PORT} (timeout: ${SSH_TIMEOUT}s)..."
  while true; do
    if nc -zw5 "$ip" "$SSH_PORT" 2>/dev/null; then
      if ssh -q \
          -i "$SSH_KEY" \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=5 \
          -o BatchMode=yes \
          -p "$SSH_PORT" \
          "${SSH_USER}@${ip}" \
          exit 2>/dev/null; then
        info "SSH is ready."
        return 0
      fi
    fi
    if ((elapsed >= SSH_TIMEOUT)); then
      err "SSH not ready after ${SSH_TIMEOUT}s."
      return 1
    fi
    sleep 15
    ((elapsed += 15))
    info "  Still waiting for SSH... (${elapsed}s elapsed)"
  done
}

# ── Code sync ─────────────────────────────────────────────────────────────────
sync_code() {
  local ip="$1"
  info "rsyncing repo to ${SSH_USER}@${ip}:${REMOTE_DIR} ..."
  if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run] rsync $REPO_ROOT/ ${SSH_USER}@${ip}:${REMOTE_DIR}/"
    return 0
  fi
  ssh -q \
    -i "$SSH_KEY" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -p "$SSH_PORT" \
    "${SSH_USER}@${ip}" \
    "mkdir -p ${REMOTE_DIR}"

  rsync -az --progress \
    --exclude '.git' \
    --exclude '__pycache__' \
    --exclude '*.pyc' \
    --exclude '.venv' \
    --exclude 'node_modules' \
    --exclude 'infra/runpod/.terraform' \
    --exclude 'infra/runpod/terraform.tfstate*' \
    --exclude 'infra/runpod/tfplan' \
    --exclude 'data/train' \
    -e "ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p ${SSH_PORT}" \
    "${REPO_ROOT}/" \
    "${SSH_USER}@${ip}:${REMOTE_DIR}/"
}

# ── Test execution ─────────────────────────────────────────────────────────────
run_tests() {
  local ip="$1"
  info "Running test script on pod: $(basename "$TEST_SCRIPT")"
  if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run] ssh ${SSH_USER}@${ip} bash < $TEST_SCRIPT"
    return 0
  fi
  ssh -q \
    -i "$SSH_KEY" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=120 \
    -p "$SSH_PORT" \
    "${SSH_USER}@${ip}" \
    "cd ${REMOTE_DIR} && bash -s" < "$TEST_SCRIPT"
}

# ── Single iteration ──────────────────────────────────────────────────────────
run_once() {
  local iter="$1"
  local pod_ip=""
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

  # 2. Wait for IP
  if ! pod_ip="$(wait_for_ip)"; then
    err "Could not get pod IP. Tearing down."
    _stop_watchdog
    teardown_pod || { err "Teardown also failed. Stopping loop."; cleanup_needed=0; return 2; }
    cleanup_needed=0
    trap - EXIT
    return 1
  fi

  # 3. Wait for SSH
  if ! wait_for_ssh "$pod_ip"; then
    err "SSH not reachable at $pod_ip. Tearing down."
    _stop_watchdog
    teardown_pod || { err "Teardown also failed. Stopping loop."; cleanup_needed=0; return 2; }
    cleanup_needed=0
    trap - EXIT
    return 1
  fi

  # 4. Sync code
  if [[ $NO_SYNC -eq 0 ]]; then
    if ! sync_code "$pod_ip"; then
      err "rsync failed. Tearing down."
      _stop_watchdog
      teardown_pod || { err "Teardown also failed. Stopping loop."; cleanup_needed=0; return 2; }
      cleanup_needed=0
      trap - EXIT
      return 1
    fi
  fi

  # 5. Run tests (capture exit code; always proceed to teardown)
  if ! run_tests "$pod_ip"; then
    test_exit=$?
    warn "Tests FAILED on iteration ${iter} (exit ${test_exit})."
  else
    info "Tests PASSED on iteration ${iter}."
  fi

  # 6. Stop watchdog + teardown
  _stop_watchdog
  info "Tearing down pod..."
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
