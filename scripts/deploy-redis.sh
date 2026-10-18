#!/usr/bin/env bash
# Deploy Redis across N node VMs, host-networked. Standalone for N=1; Redis Cluster for N>1.
# Redis is given its BEST single-instance multi-core config (io-threads = core count,
# persistence off) to steelman it against Zaris.
#   deploy-redis.sh <nnodes> <cores_per_node>
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$HERE/common.sh"
N="${1:?nnodes}"; CORES="${2:?cores per node}"

cluster_flags=""
[ "$N" -gt 1 ] && cluster_flags="--cluster-enabled yes --cluster-config-file nodes.conf --cluster-node-timeout 5000"

echo "[deploy-redis] N=$N cores=$CORES"
for ((i=0;i<N;i++)); do
  ip="${NODE_PUB[$i]}"; priv="${NODE_PRIV[$i]}"
  nssh "$ip" "sudo docker rm -f rbench >/dev/null 2>&1; sudo docker run -d --name rbench --network host $REDIS_IMAGE \
    redis-server --save '' --appendonly no --protected-mode no \
    --io-threads $CORES --io-threads-do-reads yes \
    --bind 0.0.0.0 --port $REDIS_PORT $cluster_flags >/dev/null && echo started_redis_n$i" &
done
wait
sleep 4
if [ "$N" -gt 1 ]; then
  seeds=""; for ((i=0;i<N;i++)); do seeds+="${NODE_PRIV[$i]}:$REDIS_PORT "; done
  echo "[deploy-redis] forming cluster: $seeds"
  nssh "${NODE_PUB[0]}" "echo yes | sudo docker run --rm -i --network host $REDIS_IMAGE \
    redis-cli --cluster create $seeds --cluster-replicas 0 2>&1 | tail -4"
  sleep 3
  nssh "${NODE_PUB[0]}" "sudo docker run --rm --network host $REDIS_IMAGE redis-cli -h ${NODE_PRIV[0]} -p $REDIS_PORT cluster info 2>&1 | grep -E 'cluster_state|cluster_known_nodes'"
else
  nssh "${NODE_PUB[0]}" "sudo docker run --rm --network host $REDIS_IMAGE redis-cli -h ${NODE_PRIV[0]} -p $REDIS_PORT ping"
fi
echo "[deploy-redis] up."
