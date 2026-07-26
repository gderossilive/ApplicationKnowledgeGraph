#!/usr/bin/env sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
infra_root="$repo_root/infra/java-webapp-oidc-demo"
compiled_template=$(mktemp)
trap 'rm -f "$compiled_template"' EXIT

az bicep build --file "$infra_root/main.bicep" --outfile "$compiled_template"
jq -e '.parameters.environmentName.value | length >= 3 and length <= 16' "$infra_root/main.parameters.json" >/dev/null
for parameter in bootstrapScriptUri javaSourceArchiveUri postgresqlPatchUri jdkArchiveUri tomcatArchiveUri mavenArchiveUri; do
  value=$(jq -r ".parameters.${parameter}.value" "$infra_root/main.parameters.json")
  case "$value" in
    https://*) ;;
    *) printf '%s must be an HTTPS URI in main.parameters.json.\n' "$parameter" >&2; exit 1 ;;
  esac
done
for parameter in javaSourceArchiveSha256 postgresqlPatchSha256 jdkArchiveSha256 tomcatArchiveSha256 mavenArchiveSha256; do
  value=$(jq -r ".parameters.${parameter}.value" "$infra_root/main.parameters.json")
  case "$value" in
    [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]*)
      [ "${#value}" -eq 64 ] || { printf '%s must be a SHA-256 checksum.\n' "$parameter" >&2; exit 1; }
      ;;
    *) printf '%s must be a SHA-256 checksum.\n' "$parameter" >&2; exit 1 ;;
  esac
done