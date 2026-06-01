#!/usr/bin/env bash
#
# Copyright (C) 2026 ScyllaDB
#
# Runs hack/kind/run-e2e-tests.sh N times with up to M concurrent workers,
# preserving each iteration's artifacts under ${ARTIFACTS}/run<i>.
#
# Inputs:
#   ARTIFACTS          (default ./kind-results) parent directory for per-run artifacts.
#   SO_E2E_RUNS        (default 100) number of iterations.
#   SO_E2E_CONCURRENCY (default 4) maximum parallel runs.
#   SO_E2E_COOLDOWN    (default 300) seconds to wait between batches (0 to disable).
#
# All other env vars (SO_IMAGE, SO_SUITE, ...) flow through to the inner
# run-e2e-tests.sh unchanged.
#
# Notes:
# - We deliberately do NOT enable `set -e`; we want every run to execute
#   regardless of earlier failures and aggregate results in summary.tsv.
# - SIGINT is handled gracefully: in-flight runs finish, no new ones start.

set -uo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-scylla-operator-e2e}"
export CLUSTER_NAME

ARTIFACTS="${ARTIFACTS:-./kind-results}"
SO_E2E_RUNS="${SO_E2E_RUNS:-25}"
SO_E2E_CONCURRENCY="${SO_E2E_CONCURRENCY:-1}"
SO_E2E_COOLDOWN="${SO_E2E_COOLDOWN:-300}"

for var in SO_E2E_RUNS SO_E2E_CONCURRENCY; do
  if ! [[ "${!var}" =~ ^[1-9][0-9]*$ ]]; then
    echo "${var} must be a positive integer, got: '${!var}'" >&2
    exit 2
  fi
done

if ! [[ "${SO_E2E_COOLDOWN}" =~ ^[0-9]+$ ]]; then
  echo "SO_E2E_COOLDOWN must be a non-negative integer, got: '${SO_E2E_COOLDOWN}'" >&2
  exit 2
fi

inner_script="hack/kind/run-e2e-tests.sh"
if [[ ! -x "${inner_script}" ]]; then
  echo "inner script not found or not executable: ${PWD}/${inner_script}" >&2
  echo "Please run this script from the scylla-operator repository root." >&2
  exit 2
fi

mkdir -p -- "${ARTIFACTS}"
ARTIFACTS="$( cd -- "${ARTIFACTS}" && pwd )"
export ARTIFACTS

# Build the operator image once before the loop so iterations reuse it.
source "$( dirname "${inner_script}" )/lib.sh"
build-and-push-operator-image "$( cd -- "$( dirname "${inner_script}" )/../.." && pwd )"

# Replace imagePullPolicy so repeated runs don't re-pull the same image.
sed -i 's/imagePullPolicy: Always/imagePullPolicy: IfNotPresent/g' hack/.ci/lib/e2e.sh

# Clear output directory to avoid pollution from previous runs.
rm -rf -- "${ARTIFACTS:?}"/*

summary_tsv="${ARTIFACTS}/summary.tsv"
printf 'run\texit_code\thas_e2e_json\thas_junit\tstart_ts\tend_ts\tduration_seconds\n' > "${summary_tsv}"

STOP=0
on_sigint() {
  STOP=1
  echo "" >&2
  echo "SIGINT received; waiting for in-flight runs to finish." >&2
}
trap on_sigint INT

# reset-scylla-manager restarts the scylla-manager backend and manager itself
# with a fresh PVC to prevent commitlog accumulation and OOM on replay.
reset-scylla-manager() {
  local ns="scylla-manager"
  local sts="scylla-manager-cluster-manager-dc-manager-rack"
  local pvc="data-scylla-manager-cluster-manager-dc-manager-rack-0"
  local deploy="scylla-manager"
  local sc="scylla-manager-cluster"

  echo "--- Resetting scylla-manager: scaling down, deleting PVC, scaling up ---"

  # Scale down the StatefulSet to 0.
  kubectl -n="${ns}" scale statefulset/"${sts}" --replicas=0
  kubectl -n="${ns}" rollout status statefulset/"${sts}" --timeout=120s

  # Delete the PVC to purge accumulated data.
  kubectl -n="${ns}" delete pvc/"${pvc}" --wait=true --timeout=60s || true

  # Scale back up — the operator will recreate the PVC.
  kubectl -n="${ns}" scale statefulset/"${sts}" --replicas=1

  # Restart the manager deployment so it reconnects cleanly.
  kubectl -n="${ns}" rollout restart deployment/"${deploy}"

  # Wait for both to become ready.
  kubectl -n="${ns}" rollout status statefulset/"${sts}" --timeout=300s
  kubectl -n="${ns}" rollout status deployment/"${deploy}" --timeout=300s

  # Wait for ScyllaCluster conditions.
  kubectl -n="${ns}" wait --timeout=300s --for='condition=Progressing=False' scyllaclusters.scylla.scylladb.com/"${sc}"
  kubectl -n="${ns}" wait --timeout=300s --for='condition=Degraded=False' scyllaclusters.scylla.scylladb.com/"${sc}"
  kubectl -n="${ns}" wait --timeout=300s --for='condition=Available=True' scyllaclusters.scylla.scylladb.com/"${sc}"

  echo "--- scylla-manager reset complete ---"
}

run_one() {
  local i="$1"
  local run_dir="${ARTIFACTS}/run${i}"
  mkdir -p -- "${run_dir}"

  # Reset scylla-manager between runs to prevent data accumulation.
  if (( i > 1 )); then
    reset-scylla-manager 2>&1 | tee "${run_dir}/reset-manager.log" || true
  fi

  local start_epoch start_ts
  start_epoch="$( date +%s )"
  start_ts="$( date -u +%FT%TZ )"

  echo "=== [${start_ts}] run ${i}/${SO_E2E_RUNS} starting ==="

  local rc=0
  ARTIFACTS="${run_dir}" "${inner_script}" \
    > "${run_dir}/wrapper.stdout.log" 2> "${run_dir}/wrapper.stderr.log" \
    || rc=$?

  local end_epoch end_ts duration
  end_epoch="$( date +%s )"
  end_ts="$( date -u +%FT%TZ )"
  duration=$(( end_epoch - start_epoch ))

  echo "${rc}" > "${run_dir}/exit_code"

  local has_json=false has_junit=false
  [[ -f "${run_dir}/e2e.json" ]] && has_json=true
  [[ -f "${run_dir}/junit.e2e.xml" ]] && has_junit=true

  # Single printf < PIPE_BUF (4096) — atomic on Linux.
  printf 'run%d\t%d\t%s\t%s\t%s\t%s\t%d\n' \
    "${i}" "${rc}" "${has_json}" "${has_junit}" \
    "${start_ts}" "${end_ts}" "${duration}" >> "${summary_tsv}"

  local status="OK"
  if [[ "${rc}" -ne 0 ]]; then
    status="FAILED (rc=${rc})"
  fi
  echo "=== [${end_ts}] run ${i}/${SO_E2E_RUNS} ${status} duration=${duration}s ==="
}

# --- Concurrency loop ---
declare -a pids=()
declare -A pid_to_run=()
next_run=1

while (( next_run <= SO_E2E_RUNS || ${#pids[@]} > 0 )); do
  # Launch workers up to concurrency limit.
  while (( ${#pids[@]} < SO_E2E_CONCURRENCY && next_run <= SO_E2E_RUNS && STOP == 0 )); do
    run_one "${next_run}" &
    local_pid=$!
    pids+=("${local_pid}")
    pid_to_run[${local_pid}]="${next_run}"
    (( next_run++ ))
  done

  # Nothing running — break (happens when STOP=1 and all drained).
  if (( ${#pids[@]} == 0 )); then
    break
  fi

  # Wait for any one child to finish.
  wait -n "${pids[@]}" 2>/dev/null || true

  # Reap finished PIDs.
  alive=()
  for pid in "${pids[@]}"; do
    if kill -0 "${pid}" 2>/dev/null; then
      alive+=("${pid}")
    else
      unset "pid_to_run[${pid}]"
    fi
  done
  pids=("${alive[@]+"${alive[@]}"}")

  # Cooldown between batches — sleep unless stopped or no more runs to launch.
  if (( SO_E2E_COOLDOWN > 0 && next_run <= SO_E2E_RUNS && STOP == 0 && ${#pids[@]} == 0 )); then
    echo "--- cooldown: sleeping ${SO_E2E_COOLDOWN}s before next batch ---"
    sleep "${SO_E2E_COOLDOWN}" &
    wait $! 2>/dev/null || true
  fi
done

# --- Summary ---
executed=$(( $( wc -l < "${summary_tsv}" ) - 1 ))
failed=$( awk -F'\t' 'NR>1 && $2 != "0" { c++ } END { print c+0 }' "${summary_tsv}" )

echo ""
echo "===== Summary ====="
if command -v column &>/dev/null; then
  column -t -s $'\t' "${summary_tsv}"
else
  cat "${summary_tsv}"
fi
echo "==================="
echo "Executed: ${executed}/${SO_E2E_RUNS}  Failed: ${failed}  Stopped early: $([[ "${STOP}" -ne 0 ]] && echo yes || echo no)"

if (( failed > 0 || STOP != 0 )); then
  exit 1
fi
exit 0
