#!/usr/bin/env bash
# First-boot web bootstrap. No secret is embedded in this file.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
REGION="__REGION__"
DB_HOST="__DB_PRIVATE_IP__"
REPO_URL="__REPO_URL__"
PARAMETER_NAME="/webstack/db-password"
exec > >(tee -a /var/log/web-userdata.log) 2>&1
trap 'rc=$?; echo "ERROR: Web bootstrap failed near line ${LINENO} (exit ${rc})." >&2; exit "$rc"' ERR

echo "Starting WebStack web bootstrap..."
[[ "$DB_HOST" =~ ^10\.20\.2\.[0-9]{1,3}$ ]] || { echo "Invalid rendered DB private IP" >&2; exit 1; }
[[ "$REPO_URL" == https://github.com/* ]] || { echo "Set REPO_URL to a public HTTPS GitHub repository URL" >&2; exit 1; }

apt-get update
apt-get install -y nginx python3-venv python3-pip git curl unzip ca-certificates
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

rm -rf /tmp/webstack-src
git clone --depth 1 --branch main "$REPO_URL" /tmp/webstack-src
for file in app/app.py app/requirements.txt deploy/systemd/webstack.service deploy/nginx/webstack.conf; do
  [[ -f "/tmp/webstack-src/$file" ]] || { echo "Missing repository file: $file" >&2; exit 1; }
done

install -d -o root -g root -m 0755 /opt/webstack /etc/webstack
cp -a /tmp/webstack-src/app/. /opt/webstack/
python3 -m venv /opt/webstack/venv
/opt/webstack/venv/bin/python -m pip install --upgrade pip
/opt/webstack/venv/bin/python -m pip install -r /opt/webstack/requirements.txt

DB_PASS=""
for attempt in {1..12}; do
  if DB_PASS="$(aws ssm get-parameter --name "$PARAMETER_NAME" --with-decryption --query 'Parameter.Value' --output text --region "$REGION" --no-cli-pager 2>>/var/log/web-ssm-errors.log)"; then
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

# Root-only environment file; systemd reads it before dropping privileges.
umask 077
{
  printf 'DB_HOST=%s\n' "$DB_HOST"
  printf 'DB_PORT=3306\n'
  printf 'DB_USER=webstack_app\n'
  printf 'DB_PASSWORD=%s\n' "$DB_PASS"
  printf 'DB_NAME=webstack_db\n'
} > /etc/webstack/webstack.env
chown root:root /etc/webstack/webstack.env
chmod 600 /etc/webstack/webstack.env
unset DB_PASS

if ! id webstack >/dev/null 2>&1; then
  useradd --system --user-group --home-dir /opt/webstack --shell /usr/sbin/nologin webstack
fi
usermod -a -G www-data webstack
chown -R webstack:www-data /opt/webstack
chmod 0750 /opt/webstack

cp /tmp/webstack-src/deploy/systemd/webstack.service /etc/systemd/system/webstack.service
cp /tmp/webstack-src/deploy/nginx/webstack.conf /etc/nginx/sites-available/webstack
ln -sfn /etc/nginx/sites-available/webstack /etc/nginx/sites-enabled/webstack
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl daemon-reload
systemctl enable --now webstack
systemctl enable --now nginx
systemctl reload nginx

echo "WebStack web bootstrap completed. The /db endpoint is the end-to-end readiness check."
