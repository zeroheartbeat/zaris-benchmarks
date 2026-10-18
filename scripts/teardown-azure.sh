#!/usr/bin/env bash
# Delete the entire benchmark resource group (all VMs, disks, NICs, IPs, VNet, PPG, storage).
set -euo pipefail
RG="${RG:-RESP-PREF-RG}"
echo "Deleting resource group $RG (irreversible)..."
az group delete -n "$RG" --yes --no-wait
echo "Delete submitted."
