#!/usr/bin/env bash
# Create a temporary NAT route for DB bootstrap, launch DB then web, test /db, and remove NAT on success.
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
STATE_FILE="$SCRIPT_DIR/.state"
[[ -f "$STATE_FILE" ]] || { echo "Missing $STATE_FILE; run network/security scripts first." >&2; exit 2; }
# shellcheck disable=SC1090
source "$STATE_FILE"
: "${REGION:?}" "${OWNER:?}" "${VPC_ID:?}" "${PUB_SUBNET:?}" "${PRIV_SUBNET:?}" "${PRIV_RT:?}" "${DB_SG:?}" "${WEB_SG:?}" "${INSTANCE_PROFILE:?}"
REPO_URL="${REPO_URL:-}"
[[ "$REPO_URL" == https://github.com/* && "$REPO_URL" != *YOUR_USER* ]] || { echo "Export REPO_URL=https://github.com/mathewCodex/aws-secure-deployment.git before running." >&2; exit 2; }
for cmd in aws sed curl; do command -v "$cmd" >/dev/null || { echo "Missing local dependency: $cmd" >&2; exit 2; }; done
if [[ -e "$HOME/.ssh/webstack-key.pem" ]]; then
  echo "Refusing to overwrite $HOME/.ssh/webstack-key.pem. Use the existing private key or remove/rename it deliberately." >&2
  exit 2
fi
if aws ec2 describe-key-pairs --region "$REGION" --key-names webstack-key >/dev/null 2>&1; then
  echo "Key pair webstack-key already exists in AWS. Stop and reconcile the local key before continuing." >&2
  exit 2
fi
trap 'rc=$?; echo "ERROR: compute setup failed near line ${LINENO} (exit ${rc}). NAT resources are intentionally left for troubleshooting if created; inspect infra/.state and clean up deliberately." >&2; exit "$rc"' ERR

# Resolve the current Canonical Ubuntu 24.04 LTS AMD64 EBS gp3 AMI in this region.
AMI_ID="$(aws ssm get-parameter --region "$REGION" --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id --query 'Parameter.Value' --output text)"
[[ "$AMI_ID" == ami-* ]] || { echo "Could not resolve a valid Ubuntu AMI ID" >&2; exit 1; }
printf 'AMI_ID=%q\n' "$AMI_ID" >> "$STATE_FILE"

# Create a local private key safely. AWS returns the private half only once.
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
KEY_FILE="$HOME/.ssh/webstack-key.pem"
umask 077
aws ec2 create-key-pair --region "$REGION" --key-name webstack-key --tag-specifications "ResourceType=key-pair,Tags=[{Key=Project,Value=webstack},{Key=Owner,Value=$OWNER}]" --query 'KeyMaterial' --output text > "$KEY_FILE"
chmod 400 "$KEY_FILE"
chmod 600 "$STATE_FILE"
printf 'KEY_NAME=%q\nKEY_FILE=%q\n' 'webstack-key' "$KEY_FILE" >> "$STATE_FILE"
echo "Private SSH key written to $KEY_FILE. Never commit or send this file."

# Temporary NAT is created only for private DB bootstrapping. It is removed only after /db succeeds.
EIP_ALLOC="$(aws ec2 allocate-address --region "$REGION" --domain vpc --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=webstack-temp-nat-eip},{Key=Project,Value=webstack},{Key=Owner,Value=$OWNER}]" --query 'AllocationId' --output text)"
printf 'EIP_ALLOC=%q\n' "$EIP_ALLOC" >> "$STATE_FILE"
NAT_ID="$(aws ec2 create-nat-gateway --region "$REGION" --subnet-id "$PUB_SUBNET" --allocation-id "$EIP_ALLOC" --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=webstack-temp-nat},{Key=Project,Value=webstack},{Key=Owner,Value=$OWNER}]" --query 'NatGateway.NatGatewayId' --output text)"
printf 'NAT_ID=%q\n' "$NAT_ID" >> "$STATE_FILE"
aws ec2 wait nat-gateway-available --region "$REGION" --nat-gateway-ids "$NAT_ID"
aws ec2 create-route --region "$REGION" --route-table-id "$PRIV_RT" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_ID" >/dev/null

echo "Rendering DB user data for region $REGION..."
sed "s|__REGION__|$REGION|g" "$ROOT_DIR/deploy/db-userdata.sh" > "$ROOT_DIR/deploy/db-userdata.rendered.sh"
bash -n "$ROOT_DIR/deploy/db-userdata.rendered.sh"
DB_TAGS="ResourceType=instance,Tags=[{Key=Name,Value=webstack-db},{Key=Project,Value=webstack},{Key=Owner,Value=$OWNER}]"
DB_VOLUME_TAGS="ResourceType=volume,Tags=[{Key=Project,Value=webstack},{Key=Owner,Value=$OWNER}]"
DB_ENI_TAGS="ResourceType=network-interface,Tags=[{Key=Project,Value=webstack},{Key=Owner,Value=$OWNER}]"
DB_ID="$(aws ec2 run-instances --region "$REGION" --image-id "$AMI_ID" --instance-type t3.micro --count 1 --key-name webstack-key --subnet-id "$PRIV_SUBNET" --security-group-ids "$DB_SG" --no-associate-public-ip-address --iam-instance-profile "Name=$INSTANCE_PROFILE" --metadata-options 'HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=1' --user-data "file://$ROOT_DIR/deploy/db-userdata.rendered.sh" --tag-specifications "$DB_TAGS" "$DB_VOLUME_TAGS" "$DB_ENI_TAGS" --query 'Instances[0].InstanceId' --output text)"
printf 'DB_ID=%q\n' "$DB_ID" >> "$STATE_FILE"
aws ec2 wait instance-running --region "$REGION" --instance-ids "$DB_ID"
aws ec2 wait instance-status-ok --region "$REGION" --instance-ids "$DB_ID"
DB_IP="$(aws ec2 describe-instances --region "$REGION" --instance-ids "$DB_ID" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
[[ "$DB_IP" =~ ^10\.20\.2\.[0-9]{1,3}$ ]] || { echo "DB private IP is not in the expected private subnet: $DB_IP" >&2; exit 1; }
printf 'DB_IP=%q\n' "$DB_IP" >> "$STATE_FILE"

echo "Rendering web user data. Repository URL is code, not a secret."
sed -e "s|__REGION__|$REGION|g" -e "s|__DB_PRIVATE_IP__|$DB_IP|g" -e "s|__REPO_URL__|$REPO_URL|g" "$ROOT_DIR/deploy/web-userdata.sh" > "$ROOT_DIR/deploy/web-userdata.rendered.sh"
bash -n "$ROOT_DIR/deploy/web-userdata.rendered.sh"
WEB_TAGS="ResourceType=instance,Tags=[{Key=Name,Value=webstack-web},{Key=Project,Value=webstack},{Key=Owner,Value=$OWNER}]"
WEB_VOLUME_TAGS="ResourceType=volume,Tags=[{Key=Project,Value=webstack},{Key=Owner,Value=$OWNER}]"
WEB_ENI_TAGS="ResourceType=network-interface,Tags=[{Key=Project,Value=webstack},{Key=Owner,Value=$OWNER}]"
WEB_ID="$(aws ec2 run-instances --region "$REGION" --image-id "$AMI_ID" --instance-type t3.micro --count 1 --key-name webstack-key --subnet-id "$PUB_SUBNET" --security-group-ids "$WEB_SG" --associate-public-ip-address --iam-instance-profile "Name=$INSTANCE_PROFILE" --metadata-options 'HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=1' --user-data "file://$ROOT_DIR/deploy/web-userdata.rendered.sh" --tag-specifications "$WEB_TAGS" "$WEB_VOLUME_TAGS" "$WEB_ENI_TAGS" --query 'Instances[0].InstanceId' --output text)"
printf 'WEB_ID=%q\n' "$WEB_ID" >> "$STATE_FILE"
aws ec2 wait instance-running --region "$REGION" --instance-ids "$WEB_ID"
aws ec2 wait instance-status-ok --region "$REGION" --instance-ids "$WEB_ID"
WEB_IP="$(aws ec2 describe-instances --region "$REGION" --instance-ids "$WEB_ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
[[ "$WEB_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "No public IPv4 assigned to web instance: $WEB_IP" >&2; exit 1; }
printf 'WEB_IP=%q\n' "$WEB_IP" >> "$STATE_FILE"

# The application /db endpoint proves MySQL, SG rules, password, and private routing all work.
READY=0
for attempt in {1..90}; do
  if BODY="$(curl -fsS --max-time 6 "http://${WEB_IP}/db" 2>/dev/null)" && grep -q '"database":"connected"' <<< "$BODY"; then
    READY=1
    echo "End-to-end test passed: http://${WEB_IP}/db returned database=connected."
    break
  fi
  echo "Waiting for web and DB bootstrap ($attempt/90)..."
  sleep 10
done
if [[ "$READY" -ne 1 ]]; then
  echo "Readiness test did not pass. Keeping temporary NAT route for diagnosis." >&2
  echo "Inspect /var/log/db-userdata.log and /var/log/web-userdata.log using your approved access path." >&2
  echo "Public health URL: http://${WEB_IP}/health ; DB URL: http://${WEB_IP}/db" >&2
  exit 1
fi

# Remove private default route first; then delete the temporary NAT and release its EIP.
aws ec2 delete-route --region "$REGION" --route-table-id "$PRIV_RT" --destination-cidr-block 0.0.0.0/0
aws ec2 delete-nat-gateway --region "$REGION" --nat-gateway-id "$NAT_ID" >/dev/null
aws ec2 wait nat-gateway-deleted --region "$REGION" --nat-gateway-ids "$NAT_ID"
aws ec2 release-address --region "$REGION" --allocation-id "$EIP_ALLOC"
printf 'TEMP_NAT_CLEANED=1\n' >> "$STATE_FILE"

echo "Deployment readiness passed. Temporary NAT Gateway and Elastic IP removed."
printf 'Web instance: %s\nWeb public IP: %s\nDB instance: %s\nDB private IP: %s\n' "$WEB_ID" "$WEB_IP" "$DB_ID" "$DB_IP"
echo "Private subnet has no default internet route. Verify with describe-route-tables."
