#!/usr/bin/env bash
# Run the full 9-cell matrix for a given node core-size:
#   {Redis, Zaris-RESP, Zaris-native} x {1,2,3 nodes}, each swept to server saturation.
#   run-matrix.sh <cores_per_node>
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$HERE/common.sh"
CORES="${1:?cores per node}"
SEED="${NODE_PRIV[0]}"
LOG="$HERE/../results/run-${CORES}core.log"
: > "$LOG"
say(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

for N in 1 2 3; do
  say "===== ${CORES}-core, ${N}-node ====="

  say "--- Zaris RESP N=$N (pinned-per-owner) ---"
  bash "$HERE/teardown-targets.sh"  >>"$LOG" 2>&1
  bash "$HERE/deploy-zaris.sh" "$N" resp >>"$LOG" 2>&1
  bash "$HERE/sweep-pinned.sh" "zaris-resp-${CORES}core" "$N" 2>&1 | tee -a "$LOG"

  say "--- Zaris native N=$N ---"
  bash "$HERE/teardown-targets.sh"  >>"$LOG" 2>&1
  bash "$HERE/deploy-zaris.sh" "$N" native >>"$LOG" 2>&1
  bash "$HERE/sweep-native.sh" "zaris-native-${CORES}core" "$SEED" "$N" 2>&1 | tee -a "$LOG"

  say "--- Redis N=$N (pinned-per-owner) ---"
  bash "$HERE/teardown-targets.sh"  >>"$LOG" 2>&1
  bash "$HERE/deploy-redis.sh" "$N" "$CORES" >>"$LOG" 2>&1
  bash "$HERE/sweep-pinned.sh" "redis-${CORES}core" "$N" 2>&1 | tee -a "$LOG"
done
bash "$HERE/teardown-targets.sh" >>"$LOG" 2>&1
say "===== ${CORES}-core matrix COMPLETE ====="
