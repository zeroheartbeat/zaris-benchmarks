#!/usr/bin/env bash
# Run ONE load point: memtier from NCLIENTS client VMs in parallel against the seed,
# while sampling each loaded node's CPU (mpstat) and the product container's memory.
# Prints: aggregate ops/sec, per-node CPU%, per-node container mem.
#   run-point.sh <seed_priv> <nnodes> <pipeline> <threads> <conns> <secs> <nclients>
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$HERE/common.sh"
SEED="$1"; N="$2"; PIPE="$3"; THR="$4"; CONN="$5"; SECS="$6"; NCLI="$7"
CLUSTER=$([ "$N" -gt 1 ] && echo "--cluster-mode" || echo "")
TMP=$(mktemp -d)

# start per-node samplers (mpstat avg idle over SECS, container mem)
for ((i=0;i<N;i++)); do
  ip="${NODE_PUB[$i]}"
  ssh $SSHO azureuser@"$ip" "
    idle=\$(mpstat 1 $SECS | awk '/Average:/ {print \$NF}');
    mem=\$(sudo docker stats --no-stream --format '{{.MemUsage}}' | awk '{print \$1}' | head -1);
    echo \"idle=\$idle mem=\$mem\"
  " > "$TMP/node$i.txt" 2>/dev/null &
done

# launch memtier on NCLI clients in parallel
for ((c=0;c<NCLI;c++)); do
  cip="${CLIENT_PUB[$c]}"
  ssh $SSHO azureuser@"$cip" "sudo docker run --rm --network host $MEMTIER_IMAGE \
    -s $SEED -p $RESP_PORT --data-size=$DATA_SIZE --ratio=1:1 --key-pattern=R:R \
    --threads=$THR --clients=$CONN --pipeline=$PIPE --test-time=$SECS --hide-histogram \
    --random-data --key-maximum=2000000 $CLUSTER 2>/dev/null | grep -E '^Totals'" > "$TMP/cli$c.txt" 2>/dev/null &
done
wait

# aggregate ops/sec (awk, no bc dependency)
agg=$(cat "$TMP"/cli*.txt 2>/dev/null | awk '/^Totals/ {s+=$2} END {printf "%.0f", s}')
cpu_report=""
for ((i=0;i<N;i++)); do
  line=$(cat "$TMP/node$i.txt" 2>/dev/null)
  idle=$(echo "$line" | sed -n 's/.*idle=\([0-9.]*\).*/\1/p'); mem=$(echo "$line" | sed -n 's/.*mem=\([^ ]*\).*/\1/p')
  busy=$(awk "BEGIN{printf \"%.0f\", 100-${idle:-0}}")
  cpu_report+="n$i:${busy}%/${mem} "
done
printf "PIPE=%s THR=%s CONN=%s NCLI=%s => AGG_OPS=%s | %s\n" "$PIPE" "$THR" "$CONN" "$NCLI" "$agg" "$cpu_report"
rm -rf "$TMP"
