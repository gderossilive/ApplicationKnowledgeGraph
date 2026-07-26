#!/usr/bin/env sh
set -eu

: "${AZURE_RESOURCE_GROUP:?AZURE_RESOURCE_GROUP must be set by azd}"

vm_name=$(az vm list --resource-group "$AZURE_RESOURCE_GROUP" --query '[?starts_with(name, `azoidc`)].name | [0]' --output tsv)
if [ -z "$vm_name" ]; then
  printf 'The Java OIDC VM was not found in resource group %s.\n' "$AZURE_RESOURCE_GROUP" >&2
  exit 1
fi

power_state=$(az vm get-instance-view --resource-group "$AZURE_RESOURCE_GROUP" --name "$vm_name" --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]" --output tsv)
if [ "$power_state" != 'PowerState/running' ]; then
  printf 'VM %s is not running: %s.\n' "$vm_name" "$power_state" >&2
  exit 1
fi

extension_state=$(az vm extension list --resource-group "$AZURE_RESOURCE_GROUP" --vm-name "$vm_name" --query "[?provisioningState!='Succeeded'].name" --output tsv)
if [ -n "$extension_state" ]; then
  printf 'VM %s has unsuccessful extensions: %s.\n' "$vm_name" "$extension_state" >&2
  exit 1
fi

public_ip=$(az network public-ip list --resource-group "$AZURE_RESOURCE_GROUP" --query '[?starts_with(name, `azpipoidc`)].ipAddress | [0]' --output tsv)
if [ -z "$public_ip" ]; then
  printf 'The Java OIDC public IP was not found.\n' >&2
  exit 1
fi

curl --fail --silent --show-error --retry 5 --retry-delay 5 --connect-timeout 10 "http://$public_ip/" >/dev/null
printf 'Java OIDC is reachable at http://%s/.\n' "$public_ip"