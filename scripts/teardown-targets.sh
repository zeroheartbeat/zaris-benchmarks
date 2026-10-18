#!/usr/bin/env bash
# Stop any product containers (Zaris zbench / Redis rbench) on all node VMs.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$HERE/common.sh"
for ip in "${NODE_PUB[@]}"; do
  nssh "$ip" "sudo docker rm -f zbench rbench >/dev/null 2>&1; echo cleaned_\$(hostname)" &
done
wait
echo "[teardown] product containers stopped on all nodes."
