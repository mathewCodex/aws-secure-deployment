# Cost governance, budget alerts and teardown proof

## Budget settings

`budget/budget.json` is a monthly account-wide cost budget template with a default `USD 10` limit. Edit that amount to match your own risk tolerance, but remember that a budget is a monitoring mechanism—not a hard spend cap.

`budget/notifications.json` configures:

1. `ACTUAL`, `GREATER_THAN`, threshold `80`, type `PERCENTAGE`.
2. `FORECASTED`, `GREATER_THAN`, threshold `100`, type `PERCENTAGE`.

Both use an email subscriber placeholder. `budget/create-budget.sh` replaces the placeholder with `BUDGET_EMAIL` in a temporary file and tags the budget with `Project` and `Owner`.

### Prove delivery

1. Set `BUDGET_EMAIL` to a real inbox that you can access and run `./budget/create-budget.sh` before creating infrastructure.
2. Open the AWS Budgets recipient verification email and complete the confirmation while signed into the account that created the budget.
3. In Cost Management → Budgets, confirm the recipient status is active/verified.
4. Run `aws budgets describe-notifications-for-budget --region us-east-1 --account-id "$ACCOUNT_ID" --budget-name webstack-monthly-budget` and retain a sanitized copy of the two notification definitions.
5. Retain the recipient verification email as evidence that the address is verified. For strict proof that an alert fired, also keep an actual threshold-alert email if/when generated. **Verification email is not the same thing as an actual spend alert.**

AWS Budgets verifies new email recipients and sends notifications only to verified addresses. Billing data is delayed and budgets update periodically; forecasted alerts may require several weeks of account history. See [Adding email recipients to budget notifications](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-email-recipients.html) and [Budget best practices](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-best-practices.html).

The example budget is account-wide, so existing AWS resources also count. If the grader expects only WebStack costs, configure and validate a cost-allocation-tag filter—but cost allocation tag activation can take time. Do not represent an unfiltered account-wide budget as a project-only budget.

## Costs to watch

- EC2 compute time, EBS root volumes and any retained snapshots.
- Public IPv4 addresses, including the public web server and idle Elastic IP allocations.
- NAT Gateway hourly charge, data processing and data transfer.
- Optional VPC endpoints, Instance Connect Endpoints, load balancers, logs, snapshots or other resources added during troubleshooting.
- Data transfer and resources in another region if the account uses them.

AWS's current VPC pricing page describes NAT Gateway hourly and per-GB processing charges and states that each partial NAT Gateway-hour is billed as a full hour. It lists the public IPv4 hourly charge separately. Always check current regional prices before running the lab: [Amazon VPC pricing](https://aws.amazon.com/vpc/pricing/). A NAT Gateway left running for a month creates tens of dollars in base hourly cost at the commonly listed $0.045/hour rate, before processing and public-IP charges.

The compute script removes the temporary NAT only after its `/db` readiness test succeeds. If it times out, it intentionally retains the NAT for diagnostics; that is a cost responsibility, not a completed deployment. Inspect `infra/.state`, remove the private default route that targets the temporary NAT, delete the NAT Gateway, wait for deletion, and release the associated Elastic IP once it is no longer associated.

## Teardown and evidence sequence

**Capture governance evidence before teardown** because `teardown.sh` deletes the budget and parameter, IAM groups/users/policies, SSH key pair, EC2 instances and VPC.

Run `./teardown.sh` and type `DELETE-WEBSTACK` when prompted. The script uses the generated ignored `infra/.state`; it should not guess IDs. It waits for EC2 termination, removes temporary NAT/endpoint dependencies it can identify, releases associated project Elastic IPs, removes subnets/security groups/custom route tables, detaches/deletes the IGW and VPC, removes the role/profile/policies and created human users/groups, deletes the SSM parameter and monthly budget, and optionally removes the local private key after asking you.

If a subnet still reports `DependencyViolation`, inspect the ENI description. Delete the parent AWS resource (for example an EC2 Instance Connect Endpoint) rather than trying to delete an in-use or requester-managed ENI directly. The script intentionally stops when an ENI remains.

## Post-teardown verification

```bash
# Project instances (empty output is expected after termination and propagation)
aws ec2 describe-instances --region "$REGION" \
  --filters 'Name=tag:Project,Values=webstack' \
            'Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down' \
  --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output table

# NATs in the project VPC before the VPC itself is deleted; afterwards query all available NATs in the region and inspect them.
aws ec2 describe-nat-gateways --region "$REGION" \
  --query 'NatGateways[?State==`available`].[NatGatewayId,State,VpcId]' --output table

# Allocated public IPv4 addresses in this account/region; do not delete unrelated allocations.
aws ec2 describe-addresses --region "$REGION" \
  --query 'Addresses[].[AllocationId,PublicIp,AssociationId]' --output table

# Project-owned detached EBS volumes and snapshots
aws ec2 describe-volumes --region "$REGION" \
  --filters 'Name=tag:Project,Values=webstack' 'Name=status,Values=available' \
  --query 'Volumes[].[VolumeId,Size,State,Tags]' --output table
aws ec2 describe-snapshots --region "$REGION" --owner-ids self \
  --filters 'Name=tag:Project,Values=webstack' \
  --query 'Snapshots[].[SnapshotId,State,StartTime,VolumeSize,Tags]' --output table

# The project VPC and subnets should no longer exist
aws ec2 describe-vpcs --region "$REGION" \
  --filters 'Name=tag:Project,Values=webstack' \
  --query 'Vpcs[].[VpcId,CidrBlock,State]' --output table
aws ec2 describe-subnets --region "$REGION" \
  --filters 'Name=tag:Project,Values=webstack' \
  --query 'Subnets[].[SubnetId,VpcId,CidrBlock]' --output table

# IAM and parameter checks (IAM is account-global; be sure these names belong to this lab)
aws iam list-roles --query 'Roles[?RoleName==`webstack-ec2-role`].[RoleName,Arn]' --output table
aws iam list-users --query 'Users[?UserName==`webstack-admin` || UserName==`webstack-auditor`].[UserName,Arn]' --output table
aws ssm describe-parameters --region "$REGION" \
  --parameter-filters 'Key=Name,Option=Equals,Values=/webstack/db-password' \
  --query 'Parameters[].[Name,Type,LastModifiedDate]' --output table
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
aws budgets describe-budget --region us-east-1 --account-id "$ACCOUNT_ID" \
  --budget-name webstack-monthly-budget
```

Some API output can take time to settle. Some verification commands intentionally return an AWS error when a resource is absent (for example `describe-budget`); in that case, confirm the exact resource name in the console or use the matching list command. The address list includes other projects' allocations. Inspect tag ownership before deleting anything not explicitly created by this lab. Finish by checking Billing → Bills / Cost Explorer; a resource disappearing from `describe-*` does not instantly clear charges already incurred, and billing data can lag.

## Tagging audit

The scripts apply `Project=webstack` and `Owner=$OWNER` to resources where their create/tag APIs support tags, including VPC, subnets, route tables, security groups, IGW, EC2 instances, EBS volumes, network interfaces, key pair, Elastic IP, NAT Gateway, IAM users/groups/role/profiles/managed policies, SSM parameter and budget. AWS-generated association records and AWS-managed policies themselves are not independently taggable as ordinary customer resources; record those exceptions in your audit notes rather than claiming tag support where AWS doesn't provide it.
