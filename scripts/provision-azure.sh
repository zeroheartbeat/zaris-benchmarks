#!/usr/bin/env bash
# Provision the benchmark fabric on Azure: 3 node VMs + 3 client VMs in one proximity placement
# group / VNet, install Docker + sysstat, and print the host IPs to paste into common.sh.
# Idempotent-ish: safe to re-run after a failed create. Requires: az login, an SSH public key.
#   REGION=eastus2 PUBKEY=~/.ssh/id_rsa.pub scripts/provision-azure.sh
set -euo pipefail
RG="${RG:-RESP-PREF-RG}"; REGION="${REGION:-eastus2}"
PUBKEY="${PUBKEY:?path to your ssh public key}"
NODE_SIZE="${NODE_SIZE:-Standard_F4als_v6}"      # resize to Standard_F8als_v6 for the 8-core matrix
CLIENT_SIZE="${CLIENT_SIZE:-Standard_F16als_v6}"
MYIP=$(curl -s https://api.ipify.org)

az group create -n "$RG" -l "$REGION" -o none
az ppg create -n resp-ppg -g "$RG" -l "$REGION" --type Standard -o none
az network vnet create -g "$RG" -n resp-vnet --address-prefix 10.0.0.0/16 \
  --subnet-name resp-subnet --subnet-prefix 10.0.0.0/24 -o none
az network nsg create -g "$RG" -n resp-nsg -o none
az network nsg rule create -g "$RG" --nsg-name resp-nsg -n allow-ssh --priority 1000 \
  --source-address-prefixes "$MYIP/32" --destination-port-ranges 22 --access Allow --protocol Tcp -o none

common="--image Ubuntu2204 --ppg resp-ppg --vnet-name resp-vnet --subnet resp-subnet --nsg resp-nsg \
  --admin-username azureuser --ssh-key-values $PUBKEY --public-ip-sku Standard --storage-sku Premium_LRS --no-wait"
for n in node1 node2 node3; do az vm create -g "$RG" -n resp-$n --size "$NODE_SIZE"   $common -o none; done
for c in client1 client2 client3; do az vm create -g "$RG" -n resp-$c --size "$CLIENT_SIZE" $common -o none; done

echo "waiting for VMs..."; az vm wait --created --ids $(az vm list -g "$RG" --query "[].id" -o tsv) 2>/dev/null || true
echo "=== install docker + sysstat on all VMs ==="
for ip in $(az vm list-ip-addresses -g "$RG" --query "[].virtualMachine.network.publicIpAddresses[0].ipAddress" -o tsv); do
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null azureuser@"$ip" \
    "curl -fsSL https://get.docker.com | sudo sh && sudo usermod -aG docker azureuser && sudo apt-get install -y sysstat" &
done; wait

echo "=== host IPs — paste into scripts/common.sh ==="
az vm list -g "$RG" -d --query "[].{name:name, priv:privateIps, pub:publicIps}" -o table
