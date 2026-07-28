# Java OIDC customizations

This directory owns changes to the Java OpenID Connect application. The upstream sample under `external/java-webapp-oidc-migrate-poc` is read-only reference material.

`patches/java-postgresql.patch` adapts the pinned upstream source to run on local PostgreSQL, including explicit loading of the legacy JDBC driver. Publish this file to an immutable URL and provide that URL and its SHA-256 as the `postgresqlPatchUri` and `postgresqlPatchSha256` deployment parameters.