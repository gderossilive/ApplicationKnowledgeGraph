# TailwindTraders legacy demo infrastructure

This directory provisions an isolated Azure demo environment with two Windows Server 2022 VMs:

- `*-pos-vm`: IIS, ASP.NET Core 2.2 hosting bundle, Access Database Engine 2010 x64, the precompiled POS artifact, and an environment-specific `POS.mdb`.
- `*-catalog-vm`: the minimal product endpoint consumed by the POS.

The catalog VM has no public IP. The POS VM receives a static public IP and permits temporary HTTP access on port 80. RDP remains restricted to `adminSourceCidr`. Replace temporary HTTP/IP access with DNS and TLS before any non-demo usage.

## Prepare artifacts

Build the legacy POS on a compatible Windows build host with access to the Mobilize feed defined in [nuget.config](../../external/TailwindTraders-PointOfSale/Source/Web/nuget.config). Publish a ZIP containing the web application's deployable output, including `web.config` and `TailwindPOS.ini`.

Upload the following immutable, versioned artifacts to a controlled location reachable by the VM extensions:

1. `Bootstrap-PosVm.ps1` and `Bootstrap-CatalogVm.ps1` from `scripts/`.
2. The precompiled POS ZIP and its SHA-256 hash.
3. A copy of [POS.mdb](../../external/TailwindTraders-PointOfSale/Source/WinForms/Upgraded/POS.mdb) and its SHA-256 hash.
4. A ZIP with `CatalogStub.ps1` and `catalog.json` from [catalog-stub](catalog-stub), plus its SHA-256 hash.
5. The ASP.NET Core 2.2 Hosting Bundle and Access Database Engine 2010 x64 installers, retained internally because both are legacy dependencies.

`artifacts/manifest.json` records the SHA-256 hashes of the catalog ZIP, database seed, and bootstrap scripts created in this repository. After uploading them, replace only their corresponding URI values in `main.parameters.json`; retain the recorded checksums. The POS ZIP must come from a successful Windows build and needs its own SHA-256 value. Keep the Access Database Engine installer in the controlled artifact location because the original Microsoft download endpoint is no longer stable.

Do not place passwords, SAS tokens, or other secrets in `main.bicepparam`. Supply `adminPassword` through a secure deployment parameter instead.

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
  --parameters adminPassword='<secure-value>'

az deployment group create \
  --resource-group <resource-group> \
  --template-file infra/tailwindtraders-demo/main.bicep \
  --parameters @infra/tailwindtraders-demo/main.parameters.json \
  --parameters adminPassword='<secure-value>'
```

The deployment outputs the public IP of the POS and the private catalog URL. The POS bootstrap writes the private URL into `TailwindPOS.ini`, so it does not call `backend.tailwindtraders.com`.

## Validate and operate

1. From the POS VM, request `http://10.42.2.4:8080/webbff/v1/products/1000`; expect JSON with `name` and `price`.
2. From outside Azure, verify that the catalog endpoint is unreachable.
3. Browse `http://<pos-public-ip>/` and complete a sale using a demo product code.
4. Check IIS logs and Windows Event Viewer for IIS, OLEDB, and bitness errors.
5. To reset the demo, stop IIS, replace `C:\inetpub\TailwindPOS\POS.mdb` with the seeded copy, then start IIS.
6. To roll back, redeploy a prior immutable POS artifact and checksum through the POS VM extension.

The Access database is appropriate only for low-concurrency demo traffic. Keep an expiry date and delete the resource group when the demonstration ends.