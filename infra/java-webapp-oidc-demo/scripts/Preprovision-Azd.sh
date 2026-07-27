#!/usr/bin/env sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
infra_root="$repo_root/infra/java-webapp-oidc-demo"
compiled_template=$(mktemp)
trap 'rm -f "$compiled_template"' EXIT

az bicep build --file "$infra_root/main.bicep" --outfile "$compiled_template"
jq -e '.parameters.environmentName.value | length >= 3 and length <= 16' "$infra_root/main.parameters.json" >/dev/null