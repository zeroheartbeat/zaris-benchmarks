#!/usr/bin/env bash
# Shared config for the Zaris vs Redis benchmark campaign.
# Private IPs are used for all client->server and inter-node traffic (same VNet /
# proximity placement group). Public IPs are only used for the SSH control plane.
set -uo pipefail

# --- hosts (filled by provision-azure.sh; values below are one live run) ---
NODE_PUB=(20.62.121.16 52.247.28.49 20.114.150.227)   # node1 node2 node3
NODE_PRIV=(10.0.0.4 10.0.0.6 10.0.0.8)
CLIENT_PUB=(20.97.228.88 137.116.46.139 20.62.65.228) # client1 client2 client3
CLIENT_PRIV=(10.0.0.7 10.0.0.9 10.0.0.5)

CLUSTER_ID="bench"
CLUSTER_PORT=7811
CLIENT_PORT=7861
RESP_PORT=6379
REDIS_PORT=6379            # redis uses its own containers; same port, different runs
NODE_IMAGE="clustron/zaris-node:fable4"
REDIS_IMAGE="redis:7"
MEMTIER_IMAGE="redislabs/memtier_benchmark"
DATA_SIZE=100

SCR="${SCR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
KEY="${BENCH_KEY:?set BENCH_KEY to the ssh private key path}"
SSHO="-i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12 -o ServerAliveInterval=30"

nssh() { ssh $SSHO azureuser@"$1" "$2" 2>&1 | grep -vE "Warning: Permanently|Warning: the ECDSA|Pseudo-terminal"; }
