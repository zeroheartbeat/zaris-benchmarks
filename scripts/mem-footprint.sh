#!/usr/bin/env bash
# Controlled memory footprint: load a fixed dataset of KEYS x 100-byte values into a single-node
# engine and record the container RSS, so the Zaris-vs-Redis memory comparison is apples-to-apples
# (same dataset, same value size). Reports baseline (empty) and loaded RSS.
#   mem-footprint.sh <zaris|redis> <keys>   (run after deploying that engine single-node)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$HERE/common.sh"
ENGINE="${1:?zaris|redis}"; KEYS="${2:-1000000}"
cont=$([ "$ENGINE" = "redis" ] && echo rbench || echo zbench)
node="${NODE_PUB[0]}"; priv="${NODE_PRIV[0]}"

base=$(nssh "$node" "sudo docker stats --no-stream --format '{{.MemUsage}}' $cont | awk '{print \$1}'")
echo "[$ENGINE] baseline RSS (empty): $base"
echo "[$ENGINE] loading $KEYS x 100B keys via memtier SET-only..."
nssh "${CLIENT_PUB[0]}" "sudo docker run --rm --network host $MEMTIER_IMAGE -s $priv -p $RESP_PORT \
  --data-size=100 --ratio=1:0 --key-pattern=P:P --key-minimum=1 --key-maximum=$KEYS \
  --requests=$KEYS --threads=4 --clients=50 --pipeline=32 --hide-histogram 2>/dev/null | grep -E '^Totals' | head -1"
sleep 3
dbsize=$(nssh "$node" "sudo docker run --rm --network host $REDIS_IMAGE redis-cli -h $priv -p $RESP_PORT dbsize 2>/dev/null" | tr -d '\r')
loaded=$(nssh "$node" "sudo docker stats --no-stream --format '{{.MemUsage}}' $cont | awk '{print \$1}'")
echo "[$ENGINE] dbsize=$dbsize  loaded RSS=$loaded  (dataset = ${KEYS} x 100B ~= 100MB raw)"
