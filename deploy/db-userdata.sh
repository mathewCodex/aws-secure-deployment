#!/usr/bin/env bash
# First-boot database bootstrap. No secret is embedded in this file.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
REGION="__REGION__"
PARAMETER_NAME="/webstack/db-password"
exec > >(tee -a /var/log/db-userdata.log) 2>&1
trap 'rc=$?; echo "ERROR: DB bootstrap failed near line ${LINENO} (exit ${rc})." >&2; exit "$rc"' ERR

echo "Starting WebStack database bootstrap..."
apt-get update
apt-get install -y mysql-server curl unzip ca-certificates

# Install AWS CLI v2 from AWS's official installer; do not assume an apt awscli package exists.
if ! command -v aws >/dev/null 2>&1; then
  case "$(dpkg --print-architecture)" in
    amd64) AWSCLI_ARCH="x86_64" ;;
    arm64) AWSCLI_ARCH="aarch64" ;;
    *) echo "Unsupported CPU architecture" >&2; exit 1 ;;
  esac
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWSCLI_ARCH}.zip" -o /tmp/awscliv2.zip
  unzip -oq /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install
  rm -rf /tmp/aws /tmp/awscliv2.zip
fi
aws --version

# Retry briefly for IAM propagation and initial service availability. Never echo DB_PASS.
DB_PASS=""
for attempt in {1..12}; do
  if DB_PASS="$(aws ssm get-parameter --name "$PARAMETER_NAME" --with-decryption --query 'Parameter.Value' --output text --region "$REGION" --no-cli-pager 2>>/var/log/db-ssm-errors.log)"; then
    break
  fi
  echo "Parameter retrieval attempt ${attempt} failed; retrying in 10 seconds."
  sleep 10
done
if [[ ! "$DB_PASS" =~ ^[a-fA-F0-9]{48}$ ]]; then
  unset DB_PASS
  echo "ERROR: Could not retrieve a 48-character hexadecimal database password." >&2
  exit 1
fi

# Loaded after the stock mysqld.cnf so this later bind-address setting wins.
cat > /etc/mysql/mysql.conf.d/zz-webstack.cnf <<'CNF'
[mysqld]
bind-address = 0.0.0.0
CNF
systemctl enable --now mysql
systemctl restart mysql

# The 48-character hex validation prevents SQL quoting injection in this heredoc.
mysql --protocol=socket <<SQL
CREATE DATABASE IF NOT EXISTS webstack_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'webstack_app'@'10.20.1.%' IDENTIFIED BY '${DB_PASS}';
ALTER USER 'webstack_app'@'10.20.1.%' IDENTIFIED BY '${DB_PASS}';
GRANT SELECT ON webstack_db.* TO 'webstack_app'@'10.20.1.%';
SQL
unset DB_PASS
systemctl is-active --quiet mysql
ss -lnt | grep -q '0.0.0.0:3306'
echo "WebStack database bootstrap completed successfully."
