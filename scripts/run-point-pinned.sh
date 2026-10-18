#!/usr/bin/env bash
# One CLUSTER load point, pinned-per-owner: one memtier per node (cluster-mode OFF), each driving
# its node directly with keys hash-tagged to a slot that node owns (served locally, no redirect).
# This measures the cluster's aggregate serving capacity with ideal key distribution — the fair
# way to show throughput scaling, and identical for Zaris and Redis (both emit MOVED for owner
# discovery and honor hash-tags). Samples per-node CPU/mem.
#   run-point-pinned.sh <nnodes> <pipeline> <threads> <conns> <secs>
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$HERE/common.sh"
N="$1"; PIPE="$2"; THR="$3"; CONN="$4"; SECS="$5"
TMP=$(mktemp -d)
rc(){ sudo docker run --rm --network host $REDIS_IMAGE redis-cli "$@"; }   # used remotely via nssh

# --- discover one hash-tag owned by each node, via MOVED from node0 ---
declare -a TAG
assigned=0
for c in $(seq 0 80); do
  [ "$assigned" -ge "$N" ] && break
  reply=$(nssh "${NODE_PUB[0]}" "sudo docker run --rm --network host $REDIS_IMAGE redis-cli -h ${NODE_PRIV[0]} -p $RESP_PORT set '{k$c}:p' 1 2>/dev/null" | tr -d '\r')
  if [ "$reply" = "OK" ]; then owner="${NODE_PRIV[0]}"; else owner=$(echo "$reply" | sed -n 's/.*MOVED [0-9]* \([0-9.]*\):.*/\1/p'); fi
  for ((i=0;i<N;i++)); do
    if [ "$owner" = "${NODE_PRIV[$i]}" ] && [ -z "${TAG[$i]:-}" ]; then TAG[$i]="k$c"; assigned=$((assigned+1)); fi
  done
done
for ((i=0;i<N;i++)); do [ -z "${TAG[$i]:-}" ] && { echo "ERR: no tag found for node $i" >&2; }; done

# --- per-node CPU/mem samplers ---
for ((i=0;i<N;i++)); do
  ssh $SSHO azureuser@"${NODE_PUB[$i]}" "
    idle=\$(mpstat 1 $SECS | awk '/Average:/ {print \$NF}');
    mem=\$(sudo docker stats --no-stream --format '{{.MemUsage}}' | awk '{print \$1}' | head -1);
    echo \"idle=\$idle mem=\$mem\"
  " > "$TMP/node$i.txt" 2>/dev/null &
done

# --- one memtier per node, pinned, in parallel ---
for ((i=0;i<N;i++)); do
  cip="${CLIENT_PUB[$i]}"; priv="${NODE_PRIV[$i]}"; tag="${TAG[$i]:-k0}"
  ssh $SSHO azureuser@"$cip" "sudo docker run --rm --network host $MEMTIER_IMAGE \
    -s $priv -p $RESP_PORT --data-size=$DATA_SIZE --ratio=1:1 --key-pattern=R:R \
    --key-prefix='{$tag}:' --key-maximum=2000000 \
    --threads=$THR --clients=$CONN --pipeline=$PIPE --test-time=$SECS --hide-histogram 2>/dev/null | grep -E '^Totals'" > "$TMP/cli$i.txt" 2>/dev/null &
done
wait

agg=$(cat "$TMP"/cli*.txt 2>/dev/null | awk '/^Totals/ {s+=$2} END {printf "%.0f", s}')
cpu_report=""
for ((i=0;i<N;i++)); do
  line=$(cat "$TMP/node$i.txt" 2>/dev/null)
  idle=$(echo "$line" | sed -n 's/.*idle=\([0-9.]*\).*/\1/p'); mem=$(echo "$line" | sed -n 's/.*mem=\([^ ]*\).*/\1/p')
  busy=$(awk "BEGIN{printf \"%.0f\", 100-${idle:-0}}")
  cpu_report+="n$i:${busy}%/${mem} "
done
printf "PINNED PIPE=%s THR=%s CONN=%s => AGG_OPS=%s | %s\n" "$PIPE" "$THR" "$CONN" "$agg" "$cpu_report"
rm -rf "$TMP"
