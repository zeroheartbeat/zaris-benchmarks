#!/usr/bin/env bash
# Resize the 3 node VMs to a new size (e.g. 4-core -> 8-core) in place. Deallocate -> resize ->
# start. Managed OS disks are preserved, so the loaded Docker images survive; containers must be
# redeployed afterwards (run-matrix does that). Client VMs are left untouched.
#   resize-nodes.sh <Standard_F8als_v6>
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$HERE/common.sh"
SIZE="${1:?target size, e.g. Standard_F8als_v6}"
RG="${RG:-RESP-PREF-RG}"
for n in resp-node1 resp-node2 resp-node3; do
  echo "[resize] $n -> $SIZE"
  az vm deallocate -g "$RG" -n "$n" --no-wait
done
az vm wait -g "$RG" --ids $(az vm list -g "$RG" --query "[?starts_with(name,'resp-node')].id" -o tsv) --custom "instanceView.statuses[?code=='PowerState/deallocated']" 2>/dev/null || sleep 30
for n in resp-node1 resp-node2 resp-node3; do az vm resize -g "$RG" -n "$n" --size "$SIZE" --no-wait; done
sleep 20
for n in resp-node1 resp-node2 resp-node3; do az vm start -g "$RG" -n "$n" --no-wait; done
echo "[resize] start submitted; waiting for running..."
az vm wait -g "$RG" --ids $(az vm list -g "$RG" --query "[?starts_with(name,'resp-node')].id" -o tsv) --custom "instanceView.statuses[?code=='PowerState/running']" 2>/dev/null || sleep 40
echo "[resize] nodes now $SIZE:"
az vm list -g "$RG" -d --query "[?starts_with(name,'resp-node')].{name:name, size:hardwareProfile.vmSize, ps:powerState}" -o table
