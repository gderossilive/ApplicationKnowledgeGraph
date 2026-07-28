# Java OIDC legacy demo infrastructure

This directory provisions one Ubuntu 22.04 VM for the legacy Java OpenID Connect POC. The VM installs PostgreSQL locally, builds the WAR with Java 8 and Maven, and runs it with Tomcat 8.5. PostgreSQL accepts connections only through the local loopback interface; the network security group permits public HTTP on port 80 and restricts SSH to `adminSourceCidr`.

The application now uses PostgreSQL through the JDBC driver and the [PostgreSQL schema](../../external/java-webapp-oidc-migrate-poc/dbschema.postgresql.sql). It deliberately preserves the sample's legacy username/password behavior. This is an isolated demonstration environment, not a production baseline.

## Prepare artifacts

The Custom Script extension must receive immutable artifacts because it cannot access the workstation filesystem. Publish these files to a controlled HTTPS location and update only their URI and SHA-256 values in [main.parameters.json](main.parameters.json):

1. `scripts/Bootstrap-JavaOidcVm.sh` from this directory.
2. A source ZIP containing [java-webapp-oidc-migrate-poc](../../external/java-webapp-oidc-migrate-poc).
3. [java-postgresql.patch](../../src/java-webapp-oidc/patches/java-postgresql.patch), which changes the downloaded legacy source to PostgreSQL before it builds.
4. A Java 8 JDK Linux x64 tarball, such as a pinned Temurin 8 release.
5. A Tomcat 8.5 Linux tarball, such as `apache-tomcat-8.5.100.tar.gz` from the Apache archive.
6. An Apache Maven tarball, such as `apache-maven-3.6.3-bin.tar.gz` from the Apache archive.

Use a versioned object-store URL or a Git commit-pinned URL. Compute each digest before changing the matching `*Sha256` parameter:

```bash
sha256sum <artifact-file>
```

The pre-provisioning hook intentionally fails while these values are blank, preventing a deployment based on mutable or unverified downloads.

Do not place passwords, client secrets, or access tokens in [main.parameters.json](main.parameters.json). The bootstrap receives the PostgreSQL password and Entra client secret only from protected extension settings, then creates root-owned configuration readable by the Tomcat service account.

## Deploy

The deployment follows the same Azure Developer CLI workflow as TailwindTraders. Configure Azure CLI from the repository `.env`; only `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, and `AZURE_LOCATION` are read:

```bash
bash infra/java-webapp-oidc-demo/scripts/Set-AzureContext.sh
```

Create the environment and provide Azure settings plus secure Bicep parameters. Substitute a trusted CIDR for SSH and retain the generated values outside the repository.

```bash
azd -C infra/java-webapp-oidc-demo env new java-oidc-demo
azd -C infra/java-webapp-oidc-demo env set AZURE_SUBSCRIPTION_ID '<subscription-id>'
azd -C infra/java-webapp-oidc-demo env set AZURE_LOCATION '<azure-region>'
azd -C infra/java-webapp-oidc-demo env set AZURE_RESOURCE_GROUP 'rg-java-oidc-demo'
azd -C infra/java-webapp-oidc-demo env config set infra.parameters.adminPassword '<vm-admin-password>'
azd -C infra/java-webapp-oidc-demo env config set infra.parameters.adminSourceCidr '<trusted-public-cidr>'
azd -C infra/java-webapp-oidc-demo env config set infra.parameters.tenantName '<tenant-id-or-domain>'
azd -C infra/java-webapp-oidc-demo env config set infra.parameters.clientId '<entra-client-id>'
azd -C infra/java-webapp-oidc-demo env config set infra.parameters.clientSecret '<entra-client-secret>'
azd -C infra/java-webapp-oidc-demo env config set infra.parameters.postgresqlAppPassword '<postgres-application-password>'
azd -C infra/java-webapp-oidc-demo provision --preview --no-prompt
azd -C infra/java-webapp-oidc-demo provision --no-prompt
```

The deployment outputs the static public IP, the HTTP application URL, and SSH command. The VM bootstrap creates database `javaoidc`, login `javaoidc_app`, and the `User` and `Thing` tables.

## Validate and operate

1. Browse `http://<vm-public-ip>/`; the post-provision hook verifies this endpoint.
2. SSH to the VM and verify services with `sudo systemctl status java-oidc postgresql`.
3. Verify the schema with `sudo -u postgres psql -d javaoidc -c '\dt'`.
4. Keep TCP 5432 closed in the network security group; PostgreSQL is intentionally local to the VM.

The public listener is HTTP only to preserve the legacy deployment profile. Microsoft Entra redirect URIs for non-localhost applications require HTTPS: before testing Entra sign-in, assign a DNS name, terminate TLS with a managed certificate/reverse proxy, allow TCP 443, set `require_ssl=true`, and register the HTTPS redirect URI in the Entra application. Delete the resource group after the demonstration.