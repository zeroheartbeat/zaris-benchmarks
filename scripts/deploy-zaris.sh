#!/usr/bin/env bash
# Deploy a Zaris cluster of N nodes (RF=1) across the node VMs, host-networked.
#   deploy-zaris.sh <nnodes> <resp|native>
# RESP mode enables the Redis-protocol front-end (+ cluster MOVED fan-out for N>1).
# native mode leaves RESP off; load comes through the native client port.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$HERE/common.sh"
N="${1:?nnodes}"; MODE="${2:?resp|native}"

# build nodes[] JSON for the first N nodes (private IPs, shared ports)
nodes_json=""
endpoints=""
for ((i=0;i<N;i++)); do
  ip="${NODE_PRIV[$i]}"
  comma=$([ $i -gt 0 ] && echo "," || echo "")
  pp=$([ $i -eq 0 ] && echo "true" || echo "false")
  nodes_json+="$comma{ \"id\": \"n$i\", \"host\": \"$ip\", \"clusterPort\": $CLUSTER_PORT, \"clientPort\": $CLIENT_PORT, \"preferredPrimary\": $pp }"
  endpoints+="$([ -n "$endpoints" ] && echo ",")n$i=$ip:$RESP_PORT"
done
cfg=$(cat <<JSON
{
  "clusterId": "$CLUSTER_ID",
  "nodes": [ $nodes_json ],
  "replication": { "factor": 1, "mode": "Async", "quorum": "All", "syncAckTimeoutSeconds": 5 },
  "logging": { "logLevel": { "Default": "Warning", "Clustron.Zaris": "Warning" }, "file": { "enabled": false }, "console": { "enabled": true } }
}
JSON
)

resp_env="-e ZARIS_RESP_ENABLED=true -e ZARIS_RESP_PORT=$RESP_PORT"
[ "$MODE" = "native" ] && resp_env="-e ZARIS_RESP_ENABLED=false"
cl_env=""
if [ "$MODE" = "resp" ] && [ "$N" -gt 1 ]; then
  cl_env="-e ZARIS_RESP_CLUSTER_ENABLED=true -e ZARIS_RESP_ENDPOINTS=$endpoints"
fi
# Opt-in: inline hot path (RF1) makes the native server path run inline on the socket thread
# (no shard hop / egress-lock convoy), the structural equivalent of the RESP fast path.
extra_env=""
[ -n "${INLINE_HOT_PATH:-}" ] && extra_env+=" -e ZARIS_INLINE_HOT_PATH=$INLINE_HOT_PATH"
[ -n "${INLINE_MAX_PER_CHUNK:-}" ] && extra_env+=" -e ZARIS_INLINE_MAX_PER_CHUNK=$INLINE_MAX_PER_CHUNK"

echo "[deploy-zaris] N=$N mode=$MODE endpoints=$endpoints"
for ((i=0;i<N;i++)); do
  ip="${NODE_PUB[$i]}"
  printf '%s' "$cfg" | ssh $SSHO azureuser@"$ip" "cat > /tmp/clustron.json"
  nssh "$ip" "sudo docker rm -f zbench >/dev/null 2>&1; sudo docker run -d --name zbench --network host \
    -e CLUSTRON_NODE_ID=n$i $resp_env $cl_env $extra_env \
    -v /tmp/clustron.json:/config/clustron.json $NODE_IMAGE >/dev/null && echo started_n$i" &
done
wait
echo "[deploy-zaris] waiting for readiness (cluster convergence)..."
ready=no
for t in $(seq 1 24); do
  sleep 3
  if [ "$MODE" = "resp" ]; then
    r=$(nssh "${NODE_PUB[0]}" "sudo docker run --rm --network host $REDIS_IMAGE redis-cli -h ${NODE_PRIV[0]} -p $RESP_PORT ping 2>/dev/null" | tr -d '\r')
    [ "$r" = "PONG" ] && { ready=yes; break; }
  else
    # native: a successful HELLO on the client port => node accepting
    up=$(nssh "${NODE_PUB[0]}" "timeout 2 bash -c '</dev/tcp/${NODE_PRIV[0]}/$CLIENT_PORT' 2>/dev/null && echo open")
    [ "$up" = "open" ] && { ready=yes; break; }
  fi
done
echo "[deploy-zaris] ready=$ready after ~$((t*3))s"
if [ "$MODE" = "resp" ] && [ "$N" -gt 1 ]; then
  echo -n "[deploy-zaris] RESP CLUSTER SLOTS owners: "
  nssh "${NODE_PUB[0]}" "sudo docker run --rm --network host $REDIS_IMAGE redis-cli -h ${NODE_PRIV[0]} -p $RESP_PORT cluster slots 2>/dev/null | grep -cE '^[0-9]'" | tr -d '\r'
fi
echo "[deploy-zaris] up."
