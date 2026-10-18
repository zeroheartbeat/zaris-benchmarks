#!/usr/bin/env bash
# Shared config for the Zaris vs Redis benchmark campaign.
# Private IPs are used for all client->server and inter-node traffic (same VNet /
# proximity placement group). Public IPs are only used for the SSH control plane.
set -uo pipefail

# --- hosts ---
# Fill these with your own VMs' IPs (provision-azure.sh prints them, or set them by hand).
# Public IPs are used only for the SSH control plane; private IPs carry all benchmark traffic.
# The 203.0.113.x values below are RFC 5737 documentation placeholders — replace them.
NODE_PUB=(203.0.113.11 203.0.113.12 203.0.113.13)     # node1 node2 node3 (your public IPs)
NODE_PRIV=(10.0.0.4 10.0.0.6 10.0.0.8)                # node1 node2 node3 (your VNet private IPs)
CLIENT_PUB=(203.0.113.21 203.0.113.22 203.0.113.23)   # client1 client2 client3 (your public IPs)
CLIENT_PRIV=(10.0.0.7 10.0.0.9 10.0.0.5)              # client1 client2 client3 (your VNet private IPs)

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
