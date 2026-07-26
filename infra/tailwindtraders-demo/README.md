# TailwindTraders legacy demo infrastructure

This directory provisions an isolated Azure demo environment with three Windows Server 2022 VMs:

- `*-pos-vm`: IIS, ASP.NET Core 2.2 hosting bundle, and the POS web application.
- `*-catalog-vm`: the minimal product endpoint consumed by the POS.
- `*-sql-vm`: SQL Server 2017 Express with the Tailwind POS database migrated from `POS.mdb`.

The catalog and SQL VMs have no public IP. The POS VM receives a static public IP and permits temporary HTTP access on port 80. RDP remains restricted to `adminSourceCidr`. SQL Server listens on TCP 1433 only for the POS subnet. Replace temporary HTTP/IP access with DNS and TLS before any non-demo usage.

## Prepare artifacts

The POS VM builds the legacy POS from a source archive pinned to the TailwindTraders submodule commit. During bootstrap it installs .NET SDK 2.2.207, executes `dotnet publish`, and creates `C:\TailwindDemo\artifacts\TailwindPOS.zip` before installing the site in IIS.

Upload the following immutable, versioned artifacts to a controlled location reachable by the VM extensions:

1. `Bootstrap-PosVm.ps1`, `Bootstrap-CatalogVm.ps1`, and `Bootstrap-SqlVm.ps1` from `scripts/`.
2. `Schema-TailwindPos.sql` and `Seed-TailwindPos.sql` from [database](database). The seed is generated from the authoritative [POS.mdb](../../external/TailwindTraders-PointOfSale/Source/WinForms/Upgraded/POS.mdb).
3. A ZIP with `CatalogStub.ps1` and `catalog.json` from [catalog-stub](catalog-stub), plus its SHA-256 hash.
4. A ZIP containing the full SQL Server 2017 Express x64 installation media, with `setup.exe` at any level in the ZIP and a SHA-256 hash. Keep this Microsoft binary in a controlled artifact location.

To regenerate the data seed after changing `POS.mdb`, install `mdbtools` and run:

```bash
bash infra/tailwindtraders-demo/database/Export-PosMdbToSqlServer.sh \
  external/TailwindTraders-PointOfSale/Source/WinForms/Upgraded/POS.mdb \
  infra/tailwindtraders-demo/database/Seed-TailwindPos.sql
```

`artifacts/manifest.json` records the SHA-256 hashes of repository artifacts. After uploading them, replace only URI values in `main.parameters.json`; retain their recorded checksums. Do not publish SQL Server installation media to the public repository without confirming the applicable redistribution rights.

Do not place passwords, SAS tokens, or other secrets in `main.parameters.json`. Supply `adminPassword`, `sqlAdminPassword`, and `sqlAppPassword` through secure deployment parameters instead.

## Deploy

Configure Azure CLI from the repository `.env` without importing its unrelated secrets:

```bash
bash infra/tailwindtraders-demo/scripts/Set-AzureContext.sh
```

The script reads only `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, and `AZURE_LOCATION`. If required, it opens an Azure device-code login in the configured tenant, verifies the selected subscription, and sets the CLI default location.

Populate `main.parameters.json` with non-secret, versioned artifact locations and a trusted administrator CIDR. Then validate and deploy:

```bash
az deployment group what-if \
  --resource-group <resource-group> \
  --template-file infra/tailwindtraders-demo/main.bicep \
  --parameters @infra/tailwindtraders-demo/main.parameters.json \
  --parameters adminPassword='<secure-value>' sqlAdminPassword='<secure-value>' sqlAppPassword='<secure-value>'

az deployment group create \
  --resource-group <resource-group> \
  --template-file infra/tailwindtraders-demo/main.bicep \
  --parameters @infra/tailwindtraders-demo/main.parameters.json \
  --parameters adminPassword='<secure-value>' sqlAdminPassword='<secure-value>' sqlAppPassword='<secure-value>'
```

The deployment outputs the public IP of the POS and private catalog and SQL IPs. The POS bootstrap writes the private catalog URL and SQL connection string into `TailwindPOS.ini`, so it does not call `backend.tailwindtraders.com` and no longer requires an Access provider.

## Validate and operate

1. From the POS VM, request `http://10.42.2.4:8080/webbff/v1/products/1000`; expect JSON with `name` and `price`.
2. From the POS VM, verify `Test-NetConnection 10.42.3.4 -Port 1433` succeeds; from outside Azure, verify that both private endpoints are unreachable.
3. Browse `http://<pos-public-ip>/` and complete a sale using a demo product code.
4. Check IIS logs and Windows Event Viewer for IIS and SQL Server connectivity errors.
5. To reset the demo, delete the `TailwindPOS` database on the SQL VM and rerun the SQL VM extension with the same schema and seed artifacts.
6. To roll back, redeploy prior immutable bootstrap scripts and checksums through the VM extensions.

SQL Server Express removes the Access provider and file-locking dependency, but it retains the SQL Server Express resource limits. Keep an expiry date and delete the resource group when the demonstration ends.