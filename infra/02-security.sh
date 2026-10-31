#!/usr/bin/env bash
# Create security groups, one SecureString parameter, and three distinct identity purposes.
# Safe to rerun: existing lab resources are reused; creates and duplicate ingress are skipped.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
STATE_FILE="$SCRIPT_DIR/.state"
[[ -f "$STATE_FILE" ]] || { echo "Missing $STATE_FILE; run infra/01-network.sh first." >&2; exit 2; }
# shellcheck disable=SC1090
source "$STATE_FILE"
: "${REGION:?Missing REGION in state}" "${VPC_ID:?Missing VPC_ID in state}" "${OWNER:?Missing OWNER in state}"
STUDENT_CIDR="${STUDENT_CIDR:-}"
if [[ ! "$STUDENT_CIDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/32$ ]]; then
  echo "Export STUDENT_CIDR to your public IPv4 address with /32, e.g. 198.51.100.24/32 (replace with your real IP)." >&2
  exit 2
fi
for cmd in aws jq openssl; do command -v "$cmd" >/dev/null || { echo "Missing local dependency: $cmd" >&2; exit 2; }; done
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
[[ "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || { echo "Could not determine 12-digit AWS account ID." >&2; exit 1; }

save_state() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  grep -v -E "^${key}=" "$STATE_FILE" > "$tmp" || true
  printf '%s=%q\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

skip() { echo "Already exists, skipping create: $*" >&2; }

lookup_sg() {
  aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$1" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true
}

ensure_sg() {
  local name="$1" description="$2" gid
  gid="$(lookup_sg "$name")"
  if [[ -n "$gid" && "$gid" != "None" ]]; then
    skip "security group $name ($gid)"
    aws ec2 create-tags --region "$REGION" --resources "$gid" \
      --tags "Key=Name,Value=$name" "Key=Project,Value=webstack" "Key=Owner,Value=$OWNER" >/dev/null
  else
    gid="$(aws ec2 create-security-group --region "$REGION" --group-name "$name" \
      --description "$description" --vpc-id "$VPC_ID" \
      --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$name},{Key=Project,Value=webstack},{Key=Owner,Value=$OWNER}]" \
      --query 'GroupId' --output text)"
    echo "Created security group $name ($gid)" >&2
  fi
  printf '%s\n' "$gid"
}

authorize_cidr() {
  local gid="$1" port="$2" cidr="$3" err
  if err="$(aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$gid" --protocol tcp --port "$port" --cidr "$cidr" 2>&1)"; then
    return 0
  fi
  if [[ "$err" == *InvalidPermission.Duplicate* ]]; then
    echo "Ingress already present: $gid tcp $port $cidr"
    return 0
  fi
  echo "$err" >&2
  return 1
}

authorize_sg_source() {
  local gid="$1" port="$2" source_gid="$3" err
  if err="$(aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$gid" --protocol tcp --port "$port" --source-group "$source_gid" 2>&1)"; then
    return 0
  fi
  if [[ "$err" == *InvalidPermission.Duplicate* ]]; then
    echo "Ingress already present: $gid tcp $port source $source_gid"
    return 0
  fi
  echo "$err" >&2
  return 1
}

ensure_customer_policy() {
  # Writes the policy ARN into the named variable. Do not capture stdout.
  local dest="$1" name="$2" description="$3" document="$4" arn err
  arn="arn:aws:iam::${ACCOUNT_ID}:policy/${name}"
  if aws iam get-policy --policy-arn "$arn" >/dev/null 2>&1; then
    skip "policy $name"
  elif err="$(aws iam create-policy --policy-name "$name" --description "$description" \
      --policy-document "file://$document" --tags "Key=Project,Value=webstack" "Key=Owner,Value=$OWNER" \
      --output text 2>&1)"; then
    echo "Created policy $name" >&2
  elif [[ "$err" == *EntityAlreadyExists* ]]; then
    skip "policy $name"
  else
    echo "$err" >&2
    echo "Could not create or find policy $name" >&2
    exit 1
  fi
  if [[ ${#arn} -lt 20 ]]; then
    echo "Refusing to attach an empty policy ARN for $name" >&2
    exit 1
  fi
  printf -v "$dest" '%s' "$arn"
}

IAM_ROLE="webstack-ec2-role"
INSTANCE_PROFILE="webstack-ec2-profile"
ADMIN_GROUP="webstack-admins"
AUDITOR_GROUP="webstack-auditors"
ADMIN_USER="webstack-admin"
AUDITOR_USER="webstack-auditor"
save_state ACCOUNT_ID "$ACCOUNT_ID"
save_state IAM_ROLE "$IAM_ROLE"
save_state INSTANCE_PROFILE "$INSTANCE_PROFILE"
save_state ADMIN_GROUP "$ADMIN_GROUP"
save_state AUDITOR_GROUP "$AUDITOR_GROUP"
save_state ADMIN_USER "$ADMIN_USER"
save_state AUDITOR_USER "$AUDITOR_USER"

# Security groups: SSH is restricted to the student's /32; only HTTP is world-open.
WEB_SG="$(ensure_sg webstack-web-sg 'WebStack web tier; HTTP public and SSH restricted to student IP')"
save_state WEB_SG "$WEB_SG"
DB_SG="$(ensure_sg webstack-db-sg 'WebStack database tier; MySQL only from web security group')"
save_state DB_SG "$DB_SG"
authorize_cidr "$WEB_SG" 80 "0.0.0.0/0"
authorize_cidr "$WEB_SG" 22 "$STUDENT_CIDR"
authorize_sg_source "$DB_SG" 3306 "$WEB_SG"

# Least-privilege EC2 role and profile. The instance role can read only one parameter.
if aws iam get-role --role-name "$IAM_ROLE" >/dev/null 2>&1; then
  skip "role $IAM_ROLE"
else
  aws iam create-role --role-name "$IAM_ROLE" \
    --description 'EC2 role for WebStack; may read one named SSM parameter only' \
    --assume-role-policy-document "file://$ROOT_DIR/iam/trust-policy.json" \
    --tags "Key=Project,Value=webstack" "Key=Owner,Value=$OWNER" >/dev/null
  echo "Created role $IAM_ROLE"
fi

POLICY_TMP="$(mktemp)"
trap 'rm -f "$POLICY_TMP"' EXIT
sed -e "s/123456789012/$ACCOUNT_ID/g" -e "s/us-east-1/$REGION/g" "$ROOT_DIR/iam/ssm-read-policy.json" > "$POLICY_TMP"
ensure_customer_policy READ_POLICY_ARN webstack-read-db-password 'Read only the WebStack database password parameter' "$POLICY_TMP"
save_state READ_POLICY_ARN "$READ_POLICY_ARN"
aws iam attach-role-policy --role-name "$IAM_ROLE" --policy-arn "$READ_POLICY_ARN"
rm -f "$POLICY_TMP"
trap - EXIT

if aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE" >/dev/null 2>&1; then
  skip "instance profile $INSTANCE_PROFILE"
else
  aws iam create-instance-profile --instance-profile-name "$INSTANCE_PROFILE" \
    --tags "Key=Project,Value=webstack" "Key=Owner,Value=$OWNER" >/dev/null
  echo "Created instance profile $INSTANCE_PROFILE"
fi
PROFILE_ROLE="$(aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE" --query 'InstanceProfile.Roles[0].RoleName' --output text)"
if [[ "$PROFILE_ROLE" == "$IAM_ROLE" ]]; then
  skip "role $IAM_ROLE on instance profile $INSTANCE_PROFILE"
else
  aws iam add-role-to-instance-profile --instance-profile-name "$INSTANCE_PROFILE" --role-name "$IAM_ROLE"
fi

# Human identities: no access keys or passwords are generated by this script.
if aws iam get-group --group-name "$ADMIN_GROUP" >/dev/null 2>&1; then
  skip "group $ADMIN_GROUP"
else
  aws iam create-group --group-name "$ADMIN_GROUP" >/dev/null
  echo "Created group $ADMIN_GROUP"
fi
#aws iam tag-group --group-name "$ADMIN_GROUP" --tags "Key=Project,Value=webstack" "Key=Owner,Value=$OWNER"

#aws iam tag-resource --resource-arn "arn:aws:iam::${ACCOUNT_ID}:group/${ADMIN_GROUP}" --tags "Key=Project,Value=webstack" "Key=Owner,Value=$OWNER"
aws iam attach-group-policy --group-name "$ADMIN_GROUP" --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
ensure_customer_policy MFA_POLICY_ARN webstack-admin-require-mfa 'Require MFA for administrative actions' "$ROOT_DIR/iam/admin-mfa-policy.json"
save_state MFA_POLICY_ARN "$MFA_POLICY_ARN"
aws iam attach-group-policy --group-name "$ADMIN_GROUP" --policy-arn "$MFA_POLICY_ARN"

if aws iam get-group --group-name "$AUDITOR_GROUP" >/dev/null 2>&1; then
  skip "group $AUDITOR_GROUP"
else
  aws iam create-group --group-name "$AUDITOR_GROUP" >/dev/null
  echo "Created group $AUDITOR_GROUP"
fi
#aws iam tag-group --group-name "$AUDITOR_GROUP" --tags "Key=Project,Value=webstack" "Key=Owner,Value=$OWNER"
#aws iam tag-resource --resource-arn "arn:aws:iam::${ACCOUNT_ID}:group/${AUDITOR_GROUP}" --tags "Key=Project,Value=webstack" "Key=Owner,Value=$OWNER"
aws iam attach-group-policy --group-name "$AUDITOR_GROUP" --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess
AUDITOR_POLICY_TMP="$(mktemp)"
trap 'rm -f "$AUDITOR_POLICY_TMP"' EXIT
sed -e "s/123456789012/$ACCOUNT_ID/g" -e "s/us-east-1/$REGION/g" "$ROOT_DIR/iam/auditor-deny-parameter-values-policy.json" > "$AUDITOR_POLICY_TMP"
ensure_customer_policy AUDITOR_POLICY_ARN webstack-auditor-deny-parameter-values 'Prevent read-only auditor from retrieving any SSM parameter values' "$AUDITOR_POLICY_TMP"
save_state AUDITOR_POLICY_ARN "$AUDITOR_POLICY_ARN"
aws iam attach-group-policy --group-name "$AUDITOR_GROUP" --policy-arn "$AUDITOR_POLICY_ARN"
rm -f "$AUDITOR_POLICY_TMP"
trap - EXIT

if aws iam get-user --user-name "$ADMIN_USER" >/dev/null 2>&1; then
  skip "user $ADMIN_USER"
else
  aws iam create-user --user-name "$ADMIN_USER" --tags "Key=Project,Value=webstack" "Key=Owner,Value=$OWNER" >/dev/null
  echo "Created user $ADMIN_USER"
fi
if aws iam get-user --user-name "$AUDITOR_USER" >/dev/null 2>&1; then
  skip "user $AUDITOR_USER"
else
  aws iam create-user --user-name "$AUDITOR_USER" --tags "Key=Project,Value=webstack" "Key=Owner,Value=$OWNER" >/dev/null
  echo "Created user $AUDITOR_USER"
fi
aws iam add-user-to-group --user-name "$ADMIN_USER" --group-name "$ADMIN_GROUP"
aws iam add-user-to-group --user-name "$AUDITOR_USER" --group-name "$AUDITOR_GROUP"

# Generate a password only when the parameter does not exist. Never print or store the value in .state.
if aws ssm get-parameter --region "$REGION" --name /webstack/db-password >/dev/null 2>&1; then
  skip "SSM parameter /webstack/db-password"
else
  DB_PASS="$(openssl rand -hex 24)"
  SECRET_TMP="$(mktemp)"
  chmod 600 "$SECRET_TMP"
  trap 'rm -f "$SECRET_TMP"; unset DB_PASS' EXIT
  jq -n --arg name '/webstack/db-password' --arg value "$DB_PASS" --arg description 'WebStack database application credential' \
    '{Name:$name,Value:$value,Type:"SecureString",Description:$description,Overwrite:false}' > "$SECRET_TMP"
  aws ssm put-parameter --region "$REGION" --cli-input-json "file://$SECRET_TMP" >/dev/null
  rm -f "$SECRET_TMP"
  unset DB_PASS
  trap - EXIT
  echo "Created SSM parameter /webstack/db-password"
fi
aws ssm add-tags-to-resource --region "$REGION" --resource-type Parameter --resource-id '/webstack/db-password' \
  --tags "Key=Project,Value=webstack" "Key=Owner,Value=$OWNER"

printf 'Security configured. Secret stored as SecureString (value never displayed).\n'
printf 'Web SG=%s\nDB SG=%s\nInstance profile=%s\nAdmin group/user=%s/%s\nAuditor group/user=%s/%s\n' \
  "$WEB_SG" "$DB_SG" "$INSTANCE_PROFILE" "$ADMIN_GROUP" "$ADMIN_USER" "$AUDITOR_GROUP" "$AUDITOR_USER"
echo "Set up console passwords and MFA using the IAM Console before normal use. No access keys were created."
