#!/usr/bin/env bash
# Destructive cleanup for a dedicated VPC created by this repository. Read before running.
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$ROOT_DIR/infra/.state"
[[ -f "$STATE_FILE" ]] || { echo "No infra/.state found. Refusing to guess resource IDs." >&2; exit 2; }
# shellcheck disable=SC1090
source "$STATE_FILE"
: "${REGION:?}" "${VPC_ID:?}"
printf 'This will DELETE the dedicated WebStack VPC and project IAM resources.\nVPC: %s\nRegion: %s\n' "$VPC_ID" "$REGION"
read -r -p 'Type DELETE-WEBSTACK to continue: ' CONFIRM
[[ "$CONFIRM" == "DELETE-WEBSTACK" ]] || { echo "Cancelled."; exit 1; }
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

# 1) Terminate only instance IDs stored by this deployment.
INSTANCE_IDS=()
for id in "${WEB_ID:-}" "${DB_ID:-}"; do
  [[ -n "$id" ]] || continue
  state="$(aws ec2 describe-instances --region "$REGION" --instance-ids "$id" --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || true)"
  if [[ "$state" == "pending" || "$state" == "running" || "$state" == "stopping" || "$state" == "stopped" ]]; then
    INSTANCE_IDS+=("$id")
  fi
done
if ((${#INSTANCE_IDS[@]})); then
  aws ec2 terminate-instances --region "$REGION" --instance-ids "${INSTANCE_IDS[@]}" >/dev/null
  aws ec2 wait instance-terminated --region "$REGION" --instance-ids "${INSTANCE_IDS[@]}"
fi

# 2) Remove EC2 Instance Connect Endpoints belonging to this VPC if someone created them for debugging.
EICE_IDS="$(aws ec2 describe-instance-connect-endpoints --region "$REGION" --filters "Name=vpc-#id,Values=$VPC_ID" --query 'InstanceConnectEndpoints[].InstanceConnectEndpointId' --output text 2>/dev/null || true)"
for eice in $EICE_IDS; do
  [[ -n "$eice" && "$eice" != "None" ]] || continue
  echo "Deleting VPC EC2 Instance Connect Endpoint: $eice"
  aws ec2 delete-instance-connect-endpoint --region "$REGION" --instance-connect-endpoint-id "$eice" >/dev/null || true
  for attempt in {1..60}; do
    eice_state="$(aws ec2 describe-instance-connect-endpoints --region "$REGION" --instance-connect-endpoint-ids "$eice" --query 'InstanceConnectEndpoints[0].State' --output text 2>/dev/null || true)"
    [[ -z "$eice_state" || "$eice_state" == "None" || "$eice_state" == "delete-complete" ]] && break
    sleep 5
  done
done

# 3) Delete VPC endpoints because they can own requester-managed ENIs inside subnets.
VPCE_IDS="$(aws ec2 describe-vpc-endpoints --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" --query 'VpcEndpoints[].VpcEndpointId' --output text)"
for vpce in $VPCE_IDS; do
  [[ -n "$vpce" && "$vpce" != "None" ]] || continue
  echo "Deleting VPC endpoint: $vpce"
  aws ec2 delete-vpc-endpoints --region "$REGION" --vpc-endpoint-ids "$vpce" >/dev/null
  for attempt in {1..60}; do
    vpce_state="$(aws ec2 describe-vpc-endpoints --region "$REGION" --vpc-endpoint-ids "$vpce" --query 'VpcEndpoints[0].State' --output text 2>/dev/null || true)"
    [[ -z "$vpce_state" || "$vpce_state" == "None" || "$vpce_state" == "deleted" ]] && break
    sleep 5
  done
done

# 4) Delete all NAT Gateways in this dedicated project VPC, remove their default route, then release their EIPs.
NAT_IDS="$(aws ec2 describe-nat-gateways --region "$REGION" --filter "Name=vpc-id,Values=$VPC_ID" --query 'NatGateways[?State==`available` || State==`pending` || State==`failed` || State==`deleting`].NatGatewayId' --output text)"
for nat in $NAT_IDS; do
  [[ -n "$nat" && "$nat" != "None" ]] || continue
  ALLOCS="$(aws ec2 describe-nat-gateways --region "$REGION" --nat-gateway-ids "$nat" --query 'NatGateways[0].NatGatewayAddresses[].AllocationId' --output text 2>/dev/null || true)"
  for rt in "${PRIV_RT:-}"; do
    [[ -n "$rt" ]] || continue
    route_target="$(aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$rt" --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].NatGatewayId | [0]' --output text 2>/dev/null || true)"
    if [[ "$route_target" == "$nat" ]]; then
      aws ec2 delete-route --region "$REGION" --route-table-id "$rt" --destination-cidr-block 0.0.0.0/0
    fi
  done
  echo "Deleting NAT Gateway $nat"
  aws ec2 delete-nat-gateway --region "$REGION" --nat-gateway-id "$nat" >/dev/null || true
  aws ec2 wait nat-gateway-deleted --region "$REGION" --nat-gateway-ids "$nat" || true
  for alloc in $ALLOCS; do
    [[ -n "$alloc" && "$alloc" != "None" ]] || continue
    assoc="$(aws ec2 describe-addresses --region "$REGION" --allocation-ids "$alloc" --query 'Addresses[0].AssociationId' --output text 2>/dev/null || true)"
    if [[ -z "$assoc" || "$assoc" == "None" ]]; then
      aws ec2 release-address --region "$REGION" --allocation-id "$alloc" 2>/dev/null || true
    fi
  done
done

# Also release the specifically tracked EIP if NAT was already deleted by a prior manual step.
if [[ -n "${EIP_ALLOC:-}" ]]; then
  assoc="$(aws ec2 describe-addresses --region "$REGION" --allocation-ids "$EIP_ALLOC" --query 'Addresses[0].AssociationId' --output text 2>/dev/null || true)"
  if [[ -z "$assoc" || "$assoc" == "None" ]]; then
    aws ec2 release-address --region "$REGION" --allocation-id "$EIP_ALLOC" 2>/dev/null || true
  fi
fi
# Also clean up detached project-tagged EIPs from a previous/manual NAT deletion.
# Keep any address still associated with a live resource.
PROJECT_EIPS="$(aws ec2 describe-addresses --region "$REGION" --filters 'Name=tag:Project,Values=webstack' --query 'Addresses[].AllocationId' --output text 2>/dev/null || true)"
for alloc in $PROJECT_EIPS; do
  [[ -n "$alloc" && "$alloc" != "None" ]] || continue
  assoc="$(aws ec2 describe-addresses --region "$REGION" --allocation-ids "$alloc" --query 'Addresses[0].AssociationId' --output text 2>/dev/null || true)"
  if [[ -z "$assoc" || "$assoc" == "None" ]]; then
    echo "Releasing detached Project=webstack Elastic IP allocation $alloc"
    aws ec2 release-address --region "$REGION" --allocation-id "$alloc" 2>/dev/null || true
  fi
done

# Delete any tagged/remaining project volumes that are already detached; do not touch unrelated volumes.
VOL_IDS="$(aws ec2 describe-volumes --region "$REGION" --filters "Name=tag:Project,Values=webstack" "Name=status,Values=available" --query 'Volumes[].VolumeId' --output text)"
for vol in $VOL_IDS; do [[ -n "$vol" && "$vol" != "None" ]] && aws ec2 delete-volume --region "$REGION" --volume-id "$vol"; done
# Delete project-tagged EBS snapshots owned by this account, if any were created during the lab.
SNAP_IDS="$(aws ec2 describe-snapshots --region "$REGION" --owner-ids self --filters 'Name=tag:Project,Values=webstack' --query 'Snapshots[].SnapshotId' --output text)"
for snap in $SNAP_IDS; do
  [[ -n "$snap" && "$snap" != "None" ]] || continue
  echo "Deleting project snapshot $snap"
  aws ec2 delete-snapshot --region "$REGION" --snapshot-id "$snap"
done

# 5) Wait for all network interfaces in the dedicated VPC to disappear. Never forcibly delete an in-use ENI.
for attempt in {1..60}; do
  ENI_IDS="$(aws ec2 describe-network-interfaces --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)"
  if [[ -z "$ENI_IDS" || "$ENI_IDS" == "None" ]]; then break; fi
  if [[ "$attempt" -eq 60 ]]; then
    echo "Network interfaces remain in $VPC_ID: $ENI_IDS. Inspect their descriptions/owners; refusing to delete subnets." >&2
    aws ec2 describe-network-interfaces --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status,Description:Description,Type:InterfaceType,Subnet:SubnetId,Instance:Attachment.InstanceId,Managed:RequesterManaged}' --output table >&2
    exit 1
  fi
  sleep 5
done

# 6) Delete project subnets (including any left after a partial run).
SUBNET_IDS="$(aws ec2 describe-subnets --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[].SubnetId' --output text)"
for subnet in $SUBNET_IDS; do
  [[ -n "$subnet" && "$subnet" != "None" ]] || continue
  # Try to delete Instance Connect endpoints again after the parent deletion finished.
  aws ec2 delete-subnet --region "$REGION" --subnet-id "$subnet" || {
    echo "Subnet $subnet still has dependencies. Inspect describe-network-interfaces and endpoint resources; stopping before deleting VPC." >&2
    exit 1
  }
done

# 7) Delete project security groups. The default group must remain until VPC deletion.
# Delete the database SG first because its ingress rule references the web SG.
for sg in "${DB_SG:-}" "${WEB_SG:-}"; do
  [[ -n "$sg" ]] || continue
  if aws ec2 describe-security-groups --region "$REGION" --group-ids "$sg" >/dev/null 2>&1; then
    aws ec2 delete-security-group --region "$REGION" --group-id "$sg"
  fi
done
SG_IDS="$(aws ec2 describe-security-groups --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text)"
for sg in $SG_IDS; do [[ -n "$sg" && "$sg" != "None" ]] && aws ec2 delete-security-group --region "$REGION" --group-id "$sg"; done

# 8) Delete custom route tables; leave the main route table for VPC deletion.
RT_IDS="$(aws ec2 describe-route-tables --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" --query 'RouteTables[].RouteTableId' --output text)"
for rt in $RT_IDS; do
  [[ -n "$rt" && "$rt" != "None" ]] || continue
  is_main="$(aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$rt" --query 'length(RouteTables[0].Associations[?Main==`true`])' --output text)"
  if [[ "$is_main" == "0" ]]; then
    aws ec2 delete-route-table --region "$REGION" --route-table-id "$rt"
  fi
done

# 9) Detach/delete the IGW only if it is still attached to this VPC.
IGWS="$(aws ec2 describe-internet-gateways --region "$REGION" --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query 'InternetGateways[].InternetGatewayId' --output text)"
for igw in $IGWS; do
  [[ -n "$igw" && "$igw" != "None" ]] || continue
  aws ec2 detach-internet-gateway --region "$REGION" --internet-gateway-id "$igw" --vpc-id "$VPC_ID"
  aws ec2 delete-internet-gateway --region "$REGION" --internet-gateway-id "$igw"
done

# 10) Delete the VPC after its dependencies have gone. Continue with account resources if
# the VPC was already manually removed during a previous partial teardown.
if aws ec2 describe-vpcs --region "$REGION" --vpc-ids "$VPC_ID" >/dev/null 2>&1; then
  aws ec2 delete-vpc --region "$REGION" --vpc-id "$VPC_ID"
else
  echo "VPC $VPC_ID is already absent; continuing with remaining project cleanup."
fi

# 11) Remove local account resources created for this project.
if [[ -n "${KEY_NAME:-}" ]] && aws ec2 describe-key-pairs --region "$REGION" --key-names "$KEY_NAME" >/dev/null 2>&1; then
  aws ec2 delete-key-pair --region "$REGION" --key-name "$KEY_NAME"
fi
if [[ -n "${KEY_FILE:-}" && -f "$KEY_FILE" ]]; then
  read -r -p "Delete local private key $KEY_FILE? Type yes to remove it: " REMOVE_KEY
  if [[ "$REMOVE_KEY" == "yes" ]]; then rm -f -- "$KEY_FILE"; fi
fi
aws ssm delete-parameter --region "$REGION" --name /webstack/db-password 2>/dev/null || true

ROLE="${IAM_ROLE:-}"
# Empty every instance profile containing the project role, then delete the profile.
if [[ -n "$ROLE" ]] && aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  PROFILES="$(aws iam list-instance-profiles-for-role --role-name "$ROLE" --query 'InstanceProfiles[].InstanceProfileName' --output text 2>/dev/null || true)"
  for profile in $PROFILES; do
    aws iam remove-role-from-instance-profile --instance-profile-name "$profile" --role-name "$ROLE" 2>/dev/null || true
    aws iam delete-instance-profile --instance-profile-name "$profile" 2>/dev/null || true
  done
  ATTACHED="$(aws iam list-attached-role-policies --role-name "$ROLE" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || true)"
  for arn in $ATTACHED; do [[ -n "$arn" && "$arn" != "None" ]] && aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$arn"; done
  INLINE="$(aws iam list-role-policies --role-name "$ROLE" --query 'PolicyNames[]' --output text 2>/dev/null || true)"
  for policy in $INLINE; do [[ -n "$policy" && "$policy" != "None" ]] && aws iam delete-role-policy --role-name "$ROLE" --policy-name "$policy"; done
  aws iam delete-role --role-name "$ROLE"
fi

# Remove project-created IAM users/groups only if the security script recorded their names.
# No access keys are created by this repository, but clean up if an operator added credentials.
for user in "${ADMIN_USER:-}" "${AUDITOR_USER:-}"; do
  if aws iam get-user --user-name "$user" >/dev/null 2>&1; then
    for g in $(aws iam list-groups-for-user --user-name "$user" --query 'Groups[].GroupName' --output text); do aws iam remove-user-from-group --user-name "$user" --group-name "$g"; done
    for key in $(aws iam list-access-keys --user-name "$user" --query 'AccessKeyMetadata[].AccessKeyId' --output text); do aws iam delete-access-key --user-name "$user" --access-key-id "$key"; done
    if aws iam get-login-profile --user-name "$user" >/dev/null 2>&1; then aws iam delete-login-profile --user-name "$user"; fi
    for policy in $(aws iam list-user-policies --user-name "$user" --query 'PolicyNames[]' --output text); do aws iam delete-user-policy --user-name "$user" --policy-name "$policy"; done
    for arn in $(aws iam list-attached-user-policies --user-name "$user" --query 'AttachedPolicies[].PolicyArn' --output text); do aws iam detach-user-policy --user-name "$user" --policy-arn "$arn"; done
    for mfa in $(aws iam list-mfa-devices --user-name "$user" --query 'MFADevices[].SerialNumber' --output text); do
      aws iam deactivate-mfa-device --user-name "$user" --serial-number "$mfa" || true
      if [[ "$mfa" == arn:aws:iam::*:mfa/* ]]; then aws iam delete-virtual-mfa-device --serial-number "$mfa" || true; fi
    done
    for cert in $(aws iam list-signing-certificates --user-name "$user" --query 'Certificates[].CertificateId' --output text); do aws iam delete-signing-certificate --user-name "$user" --certificate-id "$cert"; done
    for pubkey in $(aws iam list-ssh-public-keys --user-name "$user" --query 'SSHPublicKeys[].SSHPublicKeyId' --output text); do aws iam delete-ssh-public-key --user-name "$user" --ssh-public-key-id "$pubkey"; done
    for cred in $(aws iam list-service-specific-credentials --user-name "$user" --query 'ServiceSpecificCredentials[].ServiceSpecificCredentialId' --output text); do aws iam delete-service-specific-credential --user-name "$user" --service-specific-credential-id "$cred"; done
    aws iam delete-user --user-name "$user"
  fi
done
for group in "${ADMIN_GROUP:-}" "${AUDITOR_GROUP:-}"; do
  if aws iam get-group --group-name "$group" >/dev/null 2>&1; then
    for arn in $(aws iam list-attached-group-policies --group-name "$group" --query 'AttachedPolicies[].PolicyArn' --output text); do aws iam detach-group-policy --group-name "$group" --policy-arn "$arn"; done
    for policy in $(aws iam list-group-policies --group-name "$group" --query 'PolicyNames[]' --output text); do aws iam delete-group-policy --group-name "$group" --policy-name "$policy"; done
    aws iam delete-group --group-name "$group"
  fi
done
# Delete the two customer-managed policies created by this project after all attachments are removed.
for policy_arn in "${READ_POLICY_ARN:-}" "${MFA_POLICY_ARN:-}" "${AUDITOR_POLICY_ARN:-}"; do
  [[ -n "$policy_arn" ]] || continue
  aws iam delete-policy --policy-arn "$policy_arn" 2>/dev/null || true
done

# Delete only the budget recorded as created by this repository.
BUDGET_STATE="$ROOT_DIR/budget/.state"
if [[ -f "$BUDGET_STATE" ]]; then
  # shellcheck disable=SC1090
  source "$BUDGET_STATE"
  if [[ "${ACCOUNT_ID:-}" == "$(aws sts get-caller-identity --query Account --output text)" ]] && \
     aws budgets describe-budget --region us-east-1 --account-id "$ACCOUNT_ID" --budget-name "$BUDGET_NAME" >/dev/null 2>&1; then
    aws budgets delete-budget --region us-east-1 --account-id "$ACCOUNT_ID" --budget-name "$BUDGET_NAME"
  fi
  rm -f "$BUDGET_STATE"
fi

rm -f "$ROOT_DIR/deploy/db-userdata.rendered.sh" "$ROOT_DIR/deploy/web-userdata.rendered.sh"
rm -f "$STATE_FILE"
echo "Teardown commands completed. Run the verification commands in docs/COST-GOVERNANCE.md and inspect the AWS Billing console; billing data can lag."
