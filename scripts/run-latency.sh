#!/usr/bin/env bash
# Per-operation latency (unloaded service time): one request in flight at a time, so the
# reported mean latency is the true single-op round-trip, not a queueing-inflated number.
#   - RESP / Redis: memtier with --clients=1 --threads=1 --pipeline=1 (direct latency report).
#   - Native:       NativeBench --concurrency 1; at depth 1, mean latency = 1 / (ops/sec).
# Run single-node after deploying that engine. Reports avg + p50 + p99 (us) where available.
#   run-latency.sh <resp|redis|native> <seed_priv>
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$HERE/common.sh"
ENGINE="${1:?resp|redis|native}"; SEED="${2:-${NODE_PRIV[0]}}"; SECS="${3:-20}"
cip="${CLIENT_PUB[0]}"

case "$ENGINE" in
  resp|redis)
    port=$([ "$ENGINE" = "redis" ] && echo "$REDIS_PORT" || echo "$RESP_PORT")
    out=$(nssh "$cip" "sudo docker run --rm --network host $MEMTIER_IMAGE \
      -s $SEED -p $port --data-size=$DATA_SIZE --ratio=1:1 --key-pattern=R:R \
      --clients=1 --threads=1 --pipeline=1 --test-time=$SECS \
      --print-percentiles 50,99 2>/dev/null | grep -E '^Totals|Percentile'")
    echo "[$ENGINE latency] $out"
    # Totals line fields: Type Ops/sec Hits/s Misses/s Avg.Lat p50 p99 ... (memtier prints ms)
    avg=$(echo "$out" | awk '/^Totals/{print $5}')
    p50=$(echo "$out" | awk '/^Totals/{print $6}')
    p99=$(echo "$out" | awk '/^Totals/{print $7}')
    printf "ENGINE=%s  avg=%s ms  p50=%s ms  p99=%s ms\n" "$ENGINE" "$avg" "$p50" "$p99"
    ;;
  native)
    line=$(bash "$HERE/run-point-native.sh" "$SEED" 1 1 500000 1 1)
    echo "[native latency] $line"
    ops=$(echo "$line" | sed -n 's/.*MIX_OPS=\([0-9]*\).*/\1/p'); [ -z "$ops" ] && ops=0
    if [ "$ops" -gt 0 ]; then
      awk "BEGIN{printf \"ENGINE=native  mean_per_op=%.3f ms  (= 1e3/%d ops/s at concurrency 1)\n\", 1000.0/$ops, $ops}"
    else
      echo "ENGINE=native  (no ops recorded)"
    fi
    ;;
  *) echo "unknown engine $ENGINE"; exit 1;;
esac
