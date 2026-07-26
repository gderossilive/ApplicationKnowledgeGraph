#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  printf 'Usage: %s <source.mdb> <output.sql>\n' "$0" >&2
  exit 64
fi

source_mdb=$1
output_sql=$2
command -v mdb-export >/dev/null || {
  printf 'mdb-export from mdbtools is required.\n' >&2
  exit 69
}

tables=(Tickets TicketLines Customers Payments PaymentTypes Users UserRoles POS Shifts Breaks)
identity_tables=(Tickets Customers Payments Shifts Breaks)

{
  printf '%s\n' 'SET NOCOUNT ON;'
  printf '%s\n' 'IF NOT EXISTS (SELECT 1 FROM dbo.Tickets)'
  printf '%s\n' 'BEGIN'

  for table_name in "${tables[@]}"; do
    if [[ " ${identity_tables[*]} " == *" ${table_name} "* ]]; then
      printf '    SET IDENTITY_INSERT dbo.[%s] ON;\n' "$table_name"
    fi

    mdb-export -I postgres -D '%Y-%m-%d' -T '%Y-%m-%d %H:%M:%S' "$source_mdb" "$table_name" \
      | sed -E "s/INSERT INTO \"[a-z]+\"/    INSERT INTO dbo.[$table_name]/"

    if [[ " ${identity_tables[*]} " == *" ${table_name} "* ]]; then
      printf '    SET IDENTITY_INSERT dbo.[%s] OFF;\n' "$table_name"
    fi
  done

  printf '%s\n' 'END;'
} > "$output_sql"