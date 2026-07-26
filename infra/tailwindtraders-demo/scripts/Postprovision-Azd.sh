#!/usr/bin/env sh
set -eu

: "${AZURE_RESOURCE_GROUP:?AZURE_RESOURCE_GROUP must be set by azd}"

vm_names=$(az vm list --resource-group "$AZURE_RESOURCE_GROUP" --query '[].name' --output tsv)
vm_count=$(printf '%s\n' "$vm_names" | sed '/^$/d' | wc -l | tr -d ' ')
if [ "$vm_count" -ne 3 ]; then
  printf 'Expected three demo VMs in resource group %s, found %s.\n' "$AZURE_RESOURCE_GROUP" "$vm_count" >&2
  exit 1
fi

for vm_name in $vm_names; do
  power_state=$(az vm get-instance-view --resource-group "$AZURE_RESOURCE_GROUP" --name "$vm_name" --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]" --output tsv)
  if [ "$power_state" != 'PowerState/running' ]; then
    printf 'VM %s is not running: %s.\n' "$vm_name" "$power_state" >&2
    exit 1
  fi

  failed_extensions=$(az vm extension list --resource-group "$AZURE_RESOURCE_GROUP" --vm-name "$vm_name" --query "[?provisioningState!='Succeeded'].name" --output tsv)
  if [ -n "$failed_extensions" ]; then
    printf 'VM %s has unsuccessful extensions: %s.\n' "$vm_name" "$failed_extensions" >&2
    exit 1
  fi
done

pos_public_ip=$(az network public-ip list --resource-group "$AZURE_RESOURCE_GROUP" --query "[?starts_with(name, 'azpippos')].ipAddress | [0]" --output tsv)
if [ -z "$pos_public_ip" ]; then
  printf 'The POS public IP was not found.\n' >&2
  exit 1
fi

curl --fail --silent --show-error --retry 5 --retry-delay 5 --connect-timeout 10 "http://$pos_public_ip/" >/dev/null
printf 'Tailwind POS is reachable at http://%s/.\n' "$pos_public_ip"