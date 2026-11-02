#!/usr/bin/env bash
# One-time setup of the "ClaudePC" Windows cloud computer on Microsoft Azure.
# Run this inside Azure Cloud Shell (the >_ icon at the top of portal.azure.com, choose "Bash"):
#
#   curl -fsSL https://raw.githubusercontent.com/slimygfish101/ai-server/refs/heads/claude/aws-cloud-computer-setup-jin2ax/setup/azure-setup.sh -o azure-setup.sh
#   bash azure-setup.sh YOUR-EMAIL@example.com
#
# It is safe to run again: anything that already exists is left alone.
set -Eeuo pipefail

EMAIL="${1:-}"
CREDITS="${2:-200}"
LOCATION="${LOCATION:-eastus}"   # Virginia, closest to Brooklyn
SIZES="${SIZES:-Standard_D2s_v5 Standard_D2s_v4 Standard_D2s_v3}"   # 2 processors, 8 GB; all run Cowork's hidden computer
NAME="ClaudePC"
RG="ClaudePC"
DESK_USER="ClaudeDesk"
ROLE="ClaudePC Operator"
BOT="claude-pc-switch"
REPO_RAW="https://raw.githubusercontent.com/slimygfish101/ai-server/refs/heads/claude/aws-cloud-computer-setup-jin2ax"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31mSTOPPED: %s\033[0m\n' "$*"; exit 1; }
trap 'printf "\n\033[1;31mSTOPPED: Azure refused a step (see the message above). Copy that message to Claude. It is safe to run this again later.\033[0m\n"' ERR

[[ "$EMAIL" == *@*.* ]] || fail "Put your email after the command, e.g.: bash azure-setup.sh you@gmail.com"

SUB=$(az account show --query id -o tsv)
TENANT=$(az account show --query tenantId -o tsv)
say "Azure subscription $(az account show --query name -o tsv), location $LOCATION"

say "Switching on the Azure services we use (first time takes a few minutes)"
for ns in Microsoft.Compute Microsoft.Network Microsoft.Storage Microsoft.DevTestLab Microsoft.Consumption; do
  az provider register --namespace "$ns" --wait >/dev/null
done

say "Folder (resource group) that holds everything"
az group create -n "$RG" -l "$LOCATION" -o none
RG_ID=$(az group show -n "$RG" --query id -o tsv)

say "Permission set: start / stop / maintain this one computer only"
if [[ -z "$(az role definition list --custom-role-only true --name "$ROLE" --query '[0].name' -o tsv)" ]]; then
  az role definition create -o none --role-definition "{
    \"Name\": \"$ROLE\",
    \"Description\": \"Start, stop and run maintenance commands on ClaudePC\",
    \"Actions\": [
      \"Microsoft.Compute/virtualMachines/read\",
      \"Microsoft.Compute/virtualMachines/instanceView/read\",
      \"Microsoft.Compute/virtualMachines/start/action\",
      \"Microsoft.Compute/virtualMachines/deallocate/action\",
      \"Microsoft.Compute/virtualMachines/restart/action\",
      \"Microsoft.Compute/virtualMachines/powerOff/action\",
      \"Microsoft.Compute/virtualMachines/runCommands/read\",
      \"Microsoft.Compute/virtualMachines/runCommands/write\",
      \"Microsoft.Compute/virtualMachines/runCommands/delete\",
      \"Microsoft.Network/publicIPAddresses/read\",
      \"Microsoft.Network/networkInterfaces/read\"
    ],
    \"AssignableScopes\": [\"/subscriptions/$SUB\"]
  }"
  echo "Waiting 60 seconds for Azure to register the new permission set..."
  sleep 60
else
  echo "Already exists."
fi

say "Creating the Windows computer"
NEW_PW=0
if ! az vm show -g "$RG" -n "$NAME" -o none 2>/dev/null; then
  PW="Cp-$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-18)-7x"
  NEW_PW=1
  made=""
  for size in $SIZES; do
    echo "Trying size $size..."
    if az vm create -g "$RG" -n "$NAME" --computer-name "$NAME" -l "$LOCATION" \
         --image MicrosoftWindowsServer:WindowsServer:2025-datacenter-g2:latest \
         --size "$size" --admin-username "$DESK_USER" --admin-password "$PW" \
         --public-ip-sku Standard --public-ip-address-allocation static --nsg-rule RDP \
         --storage-sku StandardSSD_LRS --os-disk-size-gb 128 \
         --assign-identity '[system]' --role "$ROLE" --scope "$RG_ID" \
         --tags Project=ClaudePC -o none 2>/tmp/vm-error.txt; then
      made="$size"; break
    fi
    cat /tmp/vm-error.txt
  done
  [[ -n "$made" ]] || fail "Azure would not create any of the sizes ($SIZES). Copy the messages above to Claude. Nothing was charged."
  echo "Created with size $made."

  say "Installing the software (runs on the computer by itself for 20-30 minutes)"
  az vm extension set -g "$RG" --vm-name "$NAME" -o none --no-wait \
    --publisher Microsoft.Compute --name CustomScriptExtension --version 1.10 \
    --protected-settings "{
      \"fileUris\": [\"$REPO_RAW/windows/bootstrap.ps1\"],
      \"commandToExecute\": \"powershell.exe -NoProfile -ExecutionPolicy Bypass -File bootstrap.ps1 -RepoRaw $REPO_RAW -DeskUser $DESK_USER -Cloud azure -Password $PW\"
    }"
else
  echo "Computer already exists."
fi

say "Safety net: switch off every night at 2-3 AM if it is still on"
az vm auto-shutdown -g "$RG" -n "$NAME" --time 0700 -o none

say "Money alerts to $EMAIL"
START=$(date -u +%Y-%m-01T00:00:00Z)
END=$(date -u -d "$(date -u +%Y-%m-01) +1 year" +%Y-%m-01T00:00:00Z)
if ! az rest --method put -o none \
     --url "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Consumption/budgets/ClaudePC-credits?api-version=2023-05-01" \
     --body "{\"properties\":{\"category\":\"Cost\",\"amount\":$CREDITS,\"timeGrain\":\"Annually\",
       \"timePeriod\":{\"startDate\":\"$START\",\"endDate\":\"$END\"},
       \"notifications\":{
         \"fifty-left\":{\"enabled\":true,\"operator\":\"GreaterThanOrEqualTo\",\"threshold\":$(( (CREDITS - 50) * 100 / CREDITS )),\"thresholdType\":\"Actual\",\"contactEmails\":[\"$EMAIL\"]},
         \"twenty-left\":{\"enabled\":true,\"operator\":\"GreaterThanOrEqualTo\",\"threshold\":$(( (CREDITS - 20) * 100 / CREDITS )),\"thresholdType\":\"Actual\",\"contactEmails\":[\"$EMAIL\"]},
         \"forecast-all\":{\"enabled\":true,\"operator\":\"GreaterThanOrEqualTo\",\"threshold\":100,\"thresholdType\":\"Forecasted\",\"contactEmails\":[\"$EMAIL\"]}}}}" 2>/tmp/budget-error.txt; then
  cat /tmp/budget-error.txt
  echo "(Money alerts could not be created yet; new accounts sometimes need a day. Tell Claude. Everything else is fine.)"
fi

say "Limited key for Claude (on/off + maintenance of this one computer only)"
NEW_KEY=0
if [[ -z "$(az ad sp list --display-name "$BOT" --query '[0].appId' -o tsv)" ]]; then
  read -r KEY_ID KEY_SECRET < <(az ad sp create-for-rbac --name "$BOT" --role "$ROLE" --scopes "$RG_ID" \
       --query '[appId,password]' -o tsv | tr '\n' ' ') || true
  NEW_KEY=1
fi

IP=$(az vm show -d -g "$RG" -n "$NAME" --query publicIps -o tsv)
cat <<EOF


==================================================================
 DONE. The computer is installing its software now (about 20-30 min,
 it restarts itself once). Leave it alone until then.
==================================================================

 FOR THE WINDOWS APP (save these in the Windows App, nowhere else):
   PC name / address : $IP
   User name         : $DESK_USER
EOF
if [[ "$NEW_PW" == "1" ]]; then
  echo "   Password          : $PW"
  echo "   (shown only once; if lost, Azure's \"Reset password\" page can set a new one)"
else
  echo "   Password          : (unchanged from the first run)"
fi
if [[ "$NEW_KEY" == "1" ]]; then
cat <<EOF

 FOR CLAUDE'S ENVIRONMENT SETTINGS (NOT the chat!)
 Add these four as environment variables / secrets:
   AZURE_CLIENT_ID       = $KEY_ID
   AZURE_CLIENT_SECRET   = $KEY_SECRET
   AZURE_TENANT_ID       = $TENANT
   AZURE_SUBSCRIPTION_ID = $SUB

 This key is shown only once.
EOF
else
  echo
  echo " Claude's on/off key already exists (not shown again)."
fi
echo
echo " Now tell Claude: \"setup script finished\"."
