#!/usr/bin/env bash
# One native-protocol load point in MIXED 1:1 mode (same workload as memtier --ratio=1:1):
# NativeBench from NCLIENTS client VMs against the seed, summing MIX ops/sec, sampling node CPU/mem.
#   run-point-native.sh <seed_priv> <nnodes> <concurrency> <ops> <nclients>
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$HERE/common.sh"
SEED="$1"; N="$2"; CONC="$3"; OPS="$4"; NCLI="$5"
TMP=$(mktemp -d); SAMP=14

for ((i=0;i<N;i++)); do
  ip="${NODE_PUB[$i]}"
  ssh $SSHO azureuser@"$ip" "
    idle=\$(mpstat 1 $SAMP | awk '/Average:/ {print \$NF}');
    mem=\$(sudo docker stats --no-stream --format '{{.MemUsage}}' | awk '{print \$1}' | head -1);
    echo \"idle=\$idle mem=\$mem\"
  " > "$TMP/node$i.txt" 2>/dev/null &
done

for ((c=0;c<NCLI;c++)); do
  cip="${CLIENT_PUB[$c]}"
  ssh $SSHO azureuser@"$cip" "/tmp/NativeBench --conn 'zaris://$SEED:$CLIENT_PORT/$CLUSTER_ID' --mode mixed --keyspace 1000000 --ops $OPS --concurrency $CONC --data $DATA_SIZE --ttl 0 --label c$c 2>/dev/null | grep -E 'SUMMARY'" > "$TMP/cli$c.txt" 2>/dev/null &
done
wait

mixops=$(cat "$TMP"/cli*.txt 2>/dev/null | sed -n 's/.*MIX \([0-9,]*\) ops\/sec.*/\1/p' | tr -d ',' | awk '{s+=$1} END{printf "%.0f", s}')
cpu_report=""
for ((i=0;i<N;i++)); do
  line=$(cat "$TMP/node$i.txt" 2>/dev/null)
  idle=$(echo "$line" | sed -n 's/.*idle=\([0-9.]*\).*/\1/p'); mem=$(echo "$line" | sed -n 's/.*mem=\([^ ]*\).*/\1/p')
  busy=$(awk "BEGIN{printf \"%.0f\", 100-${idle:-0}}")
  cpu_report+="n$i:${busy}%/${mem} "
done
printf "CONC=%s OPS=%s NCLI=%s => MIX_OPS=%s | %s\n" "$CONC" "$OPS" "$NCLI" "${mixops:-0}" "$cpu_report"
rm -rf "$TMP"
