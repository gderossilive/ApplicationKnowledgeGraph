#!/usr/bin/env bash
set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
env_file="${repository_root}/.env"

if ! command -v az >/dev/null 2>&1; then
  echo 'Azure CLI is required. Install it before running this script.' >&2
  exit 1
fi

if [[ ! -f "$env_file" ]]; then
  echo "Azure configuration file not found: $env_file" >&2
  exit 1
fi

read_env_value() {
  local key=$1
  local value
  value=$(sed -n "s/^${key}=//p" "$env_file" | tail -n 1)
  [[ -n "$value" ]] || { echo "Required setting ${key} is missing from $env_file" >&2; exit 1; }
  printf '%s' "$value"
}

tenant_id=$(read_env_value 'AZURE_TENANT_ID')
subscription_id=$(read_env_value 'AZURE_SUBSCRIPTION_ID')
location=$(read_env_value 'AZURE_LOCATION')
current_tenant=$(az account show --query tenantId -o tsv 2>/dev/null || true)

if [[ "$current_tenant" != "$tenant_id" ]]; then
  az login --tenant "$tenant_id" --use-device-code >/dev/null
fi

az account set --subscription "$subscription_id"
[[ $(az account show --query tenantId -o tsv) == "$tenant_id" && $(az account show --query id -o tsv) == "$subscription_id" ]] || { echo 'Authenticated Azure context does not match .env.' >&2; exit 1; }
az config set defaults.location="$location"
echo 'Azure tenant, subscription, and default location are configured.'