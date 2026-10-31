#!/usr/bin/env bash
# Create a dedicated VPC, public subnet, private subnet, IGW and route tables.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$SCRIPT_DIR/.state"
REGION="${REGION:-us-east-1}"
OWNER="${OWNER:-}"
PROJECT="webstack"

if [[ -z "$OWNER" || ! "$OWNER" =~ ^[A-Za-z0-9._-]{2,48}$ ]]; then
  echo "Set OWNER to 2-48 letters/numbers/dot/underscore/hyphen, e.g. export OWNER=student01" >&2
  exit 2
fi
if [[ -e "$STATE_FILE" ]]; then
  echo "Refusing to overwrite $STATE_FILE. Inspect it; this script is not safe to rerun blindly." >&2
  exit 2
fi

umask 077
: > "$STATE_FILE"
chmod 600 "$STATE_FILE"
save_state() { printf '%s=%q\n' "$1" "$2" >> "$STATE_FILE"; }
tag_args=(--tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=webstack-vpc},{Key=Project,Value=$PROJECT},{Key=Owner,Value=$OWNER}]")

AZ="$(aws ec2 describe-availability-zones --region "$REGION" --filters "Name=state,Values=available" --query 'AvailabilityZones[0].ZoneName' --output text)"
[[ -n "$AZ" && "$AZ" != "None" ]] || { echo "No available AZ returned for $REGION" >&2; exit 1; }

VPC_ID="$(aws ec2 create-vpc --region "$REGION" --cidr-block 10.20.0.0/16 "${tag_args[@]}" --query 'Vpc.VpcId' --output text)"
save_state REGION "$REGION"
save_state OWNER "$OWNER"
save_state PROJECT "$PROJECT"
save_state VPC_ID "$VPC_ID"
save_state AZ "$AZ"
aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'

PUB_SUBNET="$(aws ec2 create-subnet --region "$REGION" --vpc-id "$VPC_ID" --cidr-block 10.20.1.0/24 --availability-zone "$AZ" --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=webstack-public},{Key=Project,Value=$PROJECT},{Key=Owner,Value=$OWNER}]" --query 'Subnet.SubnetId' --output text)"
save_state PUB_SUBNET "$PUB_SUBNET"
aws ec2 modify-subnet-attribute --region "$REGION" --subnet-id "$PUB_SUBNET" --map-public-ip-on-launch

PRIV_SUBNET="$(aws ec2 create-subnet --region "$REGION" --vpc-id "$VPC_ID" --cidr-block 10.20.2.0/24 --availability-zone "$AZ" --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=webstack-private},{Key=Project,Value=$PROJECT},{Key=Owner,Value=$OWNER}]" --query 'Subnet.SubnetId' --output text)"
save_state PRIV_SUBNET "$PRIV_SUBNET"

IGW_ID="$(aws ec2 create-internet-gateway --region "$REGION" --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=webstack-igw},{Key=Project,Value=$PROJECT},{Key=Owner,Value=$OWNER}]" --query 'InternetGateway.InternetGatewayId' --output text)"
save_state IGW_ID "$IGW_ID"
aws ec2 attach-internet-gateway --region "$REGION" --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"

PUB_RT="$(aws ec2 create-route-table --region "$REGION" --vpc-id "$VPC_ID" --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=webstack-public-rt},{Key=Project,Value=$PROJECT},{Key=Owner,Value=$OWNER}]" --query 'RouteTable.RouteTableId' --output text)"
save_state PUB_RT "$PUB_RT"
aws ec2 create-route --region "$REGION" --route-table-id "$PUB_RT" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null
PUB_ASSOC="$(aws ec2 associate-route-table --region "$REGION" --route-table-id "$PUB_RT" --subnet-id "$PUB_SUBNET" --query 'AssociationId' --output text)"
save_state PUB_ASSOC "$PUB_ASSOC"

PRIV_RT="$(aws ec2 create-route-table --region "$REGION" --vpc-id "$VPC_ID" --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=webstack-private-rt},{Key=Project,Value=$PROJECT},{Key=Owner,Value=$OWNER}]" --query 'RouteTable.RouteTableId' --output text)"
save_state PRIV_RT "$PRIV_RT"
PRIV_ASSOC="$(aws ec2 associate-route-table --region "$REGION" --route-table-id "$PRIV_RT" --subnet-id "$PRIV_SUBNET" --query 'AssociationId' --output text)"
save_state PRIV_ASSOC "$PRIV_ASSOC"

# Tag the VPC's automatically-created default resources too.
DEFAULT_RT="$(aws ec2 describe-route-tables --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" --query 'RouteTables[0].RouteTableId' --output text)"
DEFAULT_SG="$(aws ec2 describe-security-groups --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=default" --query 'SecurityGroups[0].GroupId' --output text)"
DEFAULT_NACL="$(aws ec2 describe-network-acls --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" "Name=default,Values=true" --query 'NetworkAcls[0].NetworkAclId' --output text)"
aws ec2 create-tags --region "$REGION" --resources "$DEFAULT_RT" "$DEFAULT_SG" "$DEFAULT_NACL" --tags "Key=Project,Value=$PROJECT" "Key=Owner,Value=$OWNER"
save_state DEFAULT_RT "$DEFAULT_RT"
save_state DEFAULT_SG "$DEFAULT_SG"
save_state DEFAULT_NACL "$DEFAULT_NACL"

echo "Network created. IDs saved (not secrets) to $STATE_FILE."
printf 'VPC=%s\nPublic subnet=%s\nPrivate subnet=%s\nAZ=%s\n' "$VPC_ID" "$PUB_SUBNET" "$PRIV_SUBNET" "$AZ"
echo "Private route table intentionally has no 0.0.0.0/0 route until the temporary NAT step."
