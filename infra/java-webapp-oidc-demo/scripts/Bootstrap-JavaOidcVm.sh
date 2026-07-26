#!/usr/bin/env bash
set -euo pipefail

source_uri=''
source_sha256=''
postgres_patch_sha256=''
jdk_uri=''
jdk_sha256=''
tomcat_uri=''
tomcat_sha256=''
maven_uri=''
maven_sha256=''
tenant=''
client_id=''
client_secret_base64=''
postgres_password_base64=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-uri) source_uri=$2 ;;
    --source-sha256) source_sha256=$2 ;;
    --postgres-patch-sha256) postgres_patch_sha256=$2 ;;
    --jdk-uri) jdk_uri=$2 ;;
    --jdk-sha256) jdk_sha256=$2 ;;
    --tomcat-uri) tomcat_uri=$2 ;;
    --tomcat-sha256) tomcat_sha256=$2 ;;
    --maven-uri) maven_uri=$2 ;;
    --maven-sha256) maven_sha256=$2 ;;
    --tenant) tenant=$2 ;;
    --client-id) client_id=$2 ;;
    --client-secret-base64) client_secret_base64=$2 ;;
    --postgres-password-base64) postgres_password_base64=$2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift 2
done

for required_value in source_uri source_sha256 postgres_patch_sha256 jdk_uri jdk_sha256 tomcat_uri tomcat_sha256 maven_uri maven_sha256 tenant client_id client_secret_base64 postgres_password_base64; do
  [[ -n ${!required_value} ]] || { echo "Missing required argument: $required_value" >&2; exit 2; }
done

artifact_root=/opt/java-oidc/artifacts
source_root=/opt/java-oidc/source
runtime_root=/opt/java-oidc/runtime
tomcat_root=/opt/java-oidc/tomcat
postgres_database=javaoidc
postgres_user=javaoidc_app
postgres_password=$(printf '%s' "$postgres_password_base64" | base64 --decode)
client_secret=$(printf '%s' "$client_secret_base64" | base64 --decode)

download_verified() {
  local uri=$1
  local destination=$2
  local expected_sha256=$3
  curl --fail --location --retry 5 --retry-delay 3 --output "$destination" "$uri"
  printf '%s  %s\n' "$expected_sha256" "$destination" | sha256sum --check --status
}

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install --yes ca-certificates curl patch postgresql unzip

install -d -m 0755 "$artifact_root" "$source_root" "$runtime_root"
download_verified "$source_uri" "$artifact_root/source.zip" "$source_sha256"
download_verified "$jdk_uri" "$artifact_root/jdk.tar.gz" "$jdk_sha256"
download_verified "$tomcat_uri" "$artifact_root/tomcat.tar.gz" "$tomcat_sha256"
download_verified "$maven_uri" "$artifact_root/maven.tar.gz" "$maven_sha256"

rm -rf "$source_root"/* "$runtime_root"/* "$tomcat_root"
unzip -q "$artifact_root/source.zip" -d "$source_root"
tar -xzf "$artifact_root/jdk.tar.gz" -C "$runtime_root"
tar -xzf "$artifact_root/tomcat.tar.gz" -C /opt/java-oidc
tar -xzf "$artifact_root/maven.tar.gz" -C "$runtime_root"

jdk_home=$(find "$runtime_root" -mindepth 1 -maxdepth 1 -type d -name '*jdk*' | head -n 1)
maven_home=$(find "$runtime_root" -mindepth 1 -maxdepth 1 -type d -name 'apache-maven-*' | head -n 1)
tomcat_extracted=$(find /opt/java-oidc -mindepth 1 -maxdepth 1 -type d -name 'apache-tomcat-*' | head -n 1)
application_root=$(find "$source_root" -type f -name pom.xml -path '*java-webapp-oidc-migrate-poc*/pom.xml' -printf '%h\n' | head -n 1)
[[ -x "$jdk_home/bin/java" && -x "$maven_home/bin/mvn" && -d "$tomcat_extracted" && -n "$application_root" ]] || { echo 'One or more source artifacts are invalid.' >&2; exit 1; }
mv "$tomcat_extracted" "$tomcat_root"

patch_file=$(dirname "$0")/java-postgresql.patch
printf '%s  %s\n' "$postgres_patch_sha256" "$patch_file" | sha256sum --check --status
patch --batch --forward --directory="$application_root" --strip=1 < "$patch_file"

export JAVA_HOME="$jdk_home"
export PATH="$JAVA_HOME/bin:$maven_home/bin:$PATH"
pushd "$application_root" >/dev/null
mvn --batch-mode --no-transfer-progress -DskipTests package
war_file=$(find target -maxdepth 1 -type f -name '*.war' | head -n 1)
[[ -n "$war_file" ]] || { echo 'Maven did not produce a WAR.' >&2; exit 1; }
popd >/dev/null

escaped_postgres_password=${postgres_password//\'/\'\'}
if ! sudo -u postgres psql --tuples-only --no-align --command "SELECT 1 FROM pg_roles WHERE rolname = '$postgres_user';" | grep -qx '1'; then
  sudo -u postgres psql --command "CREATE ROLE $postgres_user LOGIN PASSWORD '$escaped_postgres_password';"
fi
if ! sudo -u postgres psql --tuples-only --no-align --command "SELECT 1 FROM pg_database WHERE datname = '$postgres_database';" | grep -qx '1'; then
  sudo -u postgres createdb --owner="$postgres_user" "$postgres_database"
fi
sudo -u postgres psql --dbname="$postgres_database" --file="$application_root/dbschema.postgresql.sql"
sudo -u postgres psql --dbname="$postgres_database" --command "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO $postgres_user; GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO $postgres_user;"

id --system tomcat >/dev/null 2>&1 || useradd --system --home "$tomcat_root" --shell /usr/sbin/nologin tomcat
rm -rf "$tomcat_root/webapps"/*
install -m 0644 "$application_root/$war_file" "$tomcat_root/webapps/ROOT.war"
unzip -q "$tomcat_root/webapps/ROOT.war" -d "$tomcat_root/webapps/ROOT"
cat > /etc/java-oidc.properties <<EOF
authority=https://login.microsoftonline.com/
tenant=$tenant
db_host=127.0.0.1
db_name=$postgres_database
db_user=$postgres_user
db_password=$postgres_password
client_id=$client_id
secret_key=$client_secret
require_ssl=false
is_b2c=false
policy_susi=null
EOF
chown -R tomcat:tomcat "$tomcat_root"
chown root:tomcat /etc/java-oidc.properties
chmod 0640 /etc/java-oidc.properties
install -o root -g tomcat -m 0640 /etc/java-oidc.properties "$tomcat_root/webapps/ROOT/WEB-INF/local.properties"
sed -i 's/port="8080" protocol="HTTP\/1.1"/port="80" protocol="HTTP\/1.1"/' "$tomcat_root/conf/server.xml"
cat > /etc/systemd/system/java-oidc.service <<EOF
[Unit]
Description=Legacy Java OIDC application
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=tomcat
Group=tomcat
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
Environment=JAVA_HOME=$jdk_home
Environment=CATALINA_HOME=$tomcat_root
Environment=CATALINA_BASE=$tomcat_root
ExecStart=$tomcat_root/bin/catalina.sh run
ExecStop=$tomcat_root/bin/catalina.sh stop
SuccessExitStatus=143
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now java-oidc.service