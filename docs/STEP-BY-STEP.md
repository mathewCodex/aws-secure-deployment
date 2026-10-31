# Step-by-step deployment and shell/AWS CLI syntax guide

## 0. Scope and safety

This lab creates real resources in AWS. It is intended for a dedicated learning account and a dedicated VPC created by `infra/01-network.sh`. It is not a production architecture. Do not run these destructive scripts against a shared VPC or a repository containing real credentials.

The sample stack is IPv4-only and single-AZ to reduce cost and concepts. It uses Ubuntu 24.04, Nginx, Gunicorn, Flask, MySQL, Parameter Store and an IAM instance profile. All commands are written for Bash and AWS CLI v2. Install `aws`, `jq`, `openssl`, `git`, `curl`, `sed` and `bash` on your workstation before beginning.

Prefer temporary operator credentials (for example, AWS IAM Identity Center) rather than long-lived access keys. AWS recommends temporary credentials for human users and workloads, MFA and least privilege; see [IAM security best practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html).

## 1. Understand the intended network

```text
Internet
   |
Internet Gateway
   |
Public subnet 10.20.1.0/24 ── web EC2 (public IP, Nginx/Gunicorn)
                                   |
                         TCP/3306 from web SG only
                                   |
Private subnet 10.20.2.0/24 ─ database EC2 (private IP only)

During database bootstrap only:
private route 0.0.0.0/0 -> temporary NAT Gateway -> IGW
After successful /db test:
remove that default route, delete NAT Gateway and release its Elastic IP
```

The VPC `10.20.0.0/16` has a local route for internal VPC communication. The public route table has `0.0.0.0/0` to the IGW; the private route table has no permanent default internet route. A private IP can communicate inside the VPC without a NAT Gateway. The NAT is temporary only because the database boot script needs internet access to install packages and call SSM Parameter Store.

## 2. Configure the local operator environment

Run in one Bash terminal so environment variables remain available:

```bash
export REGION="us-east-1"
export OWNER="student01"
export STUDENT_CIDR="YOUR_CURRENT_PUBLIC_IPV4/32"
export BUDGET_EMAIL="your-real-inbox@example.com"
aws --version
aws sts get-caller-identity
```

Replace the example owner, email and CIDR. `STUDENT_CIDR` must be your current public IPv4 address followed by `/32`; `/32` represents one IPv4 address. The security script validates the suffix and AWS validates the CIDR. The `sts get-caller-identity` call confirms which AWS account the CLI will operate in; compare the account with the one intended for the lab.

### Bash syntax used throughout

- `#!/usr/bin/env bash`: asks the environment to find Bash and run the file with it.
- `set -Eeuo pipefail`: `-e` exits on many unhandled command failures, `-E` propagates the `ERR` trap through more contexts, `-u` treats unset variables as errors, and `pipefail` makes a pipeline fail if a command inside it fails.
- `"${VAR:-default}"`: uses `VAR` when set/non-empty, otherwise a default. `"${VAR:?message}"` stops with a message if `VAR` is missing or empty.
- `$(command)`: captures command output into a variable. Example: `ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"`.
- `[[ condition ]]`: Bash conditional test; `=~` performs a regular-expression match.
- `if ...; then ...; fi`: conditionally runs the body. `! command` negates the command's exit status.
- `for item in ...; do ...; done`: repeats a block for each word/item.
- `array=(...)` and `"${array[@]}"`: store multiple command arguments without flattening their spacing.
- `\` at end of line: continues the same command on the next line. Do not place a trailing space after the backslash.
- `> file`: writes standard output to a file, overwriting it. `>> file` appends. `2>&1` redirects standard error to the current standard-output destination. `/dev/null` discards output.
- `trap '...' ERR`: runs a handler when Bash detects an error in covered contexts; `LINENO` is used in the scripts to report where failure occurred. The secret is intentionally never printed in the handler.
- `umask 077`: makes newly created files private to their owner by default. `chmod 600 file` gives the owner read/write permission and removes permissions from group/others; `chmod 400 key.pem` makes the private key owner-read-only.
- `source file`: loads variable assignments from a local file into the current shell. Only source the generated `infra/.state` file produced by your own scripts; sourcing arbitrary input executes shell syntax.
- `file://path`: tells the AWS CLI to read a JSON policy/user-data/input from a local file; it is not a secret manager.

## 3. Create the budget before infrastructure

Run:

```bash
./budget/create-budget.sh
```

The script derives the account ID from `sts get-caller-identity`, reads `budget/budget.json`, replaces the email placeholder in a temporary JSON file, then calls `aws budgets create-budget`. It marks the budget with `Project=webstack` and `Owner=$OWNER` tags.

### What the budget JSON means

- `BudgetName`: unique name for this budget in the account.
- `BudgetLimit.Amount` and `Unit`: monthly alert threshold, template `$10 USD`.
- `TimeUnit: MONTHLY`: monthly period.
- `BudgetType: COST`: spend budget rather than usage or reservation coverage.
- `CostTypes`: tells Budgets which billing items to include/exclude; the template includes tax, credits, refunds, subscriptions and common cost types. Review the official fields when adapting the budget.
- `notifications.json` has two entries: `NotificationType=ACTUAL`, `Threshold=80`, `ThresholdType=PERCENTAGE`; and `NotificationType=FORECASTED`, `Threshold=100`, `ThresholdType=PERCENTAGE`. `ComparisonOperator=GREATER_THAN` means alert when the threshold is exceeded.
- `Subscribers` uses `SubscriptionType=EMAIL` and an address. The committed email is a placeholder; the real address is supplied from the shell and is not written to the repository.

AWS requires the recipient to verify their email before actual budget notifications are delivered. Open the verification email, follow its link while signed into the AWS account, then check the Budget page for an active/verified recipient. A verification message proves address validation, not that the 80% or forecast threshold actually fired. Budgets update on a delay; forecasts may require enough historical cost data (AWS documents about five weeks for forecast data in some budget guidance). Don't expect an immediate threshold alert simply because the budget exists. See [email recipient verification](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-email-recipients.html) and [Budgets best practices](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-best-practices.html).

Verify the configuration:

```bash
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
aws budgets describe-budget --region us-east-1 --account-id "$ACCOUNT_ID" --budget-name webstack-monthly-budget
aws budgets describe-notifications-for-budget --region us-east-1 --account-id "$ACCOUNT_ID" --budget-name webstack-monthly-budget
```

Budgets are account-level spend notifications, not a hard spending limit. A charge can occur before an alert arrives because cost data and notifications lag.

## 4. Build the network — `infra/01-network.sh`

Run:

```bash
./infra/01-network.sh
```

The script creates a dedicated VPC, enables DNS hostnames/support, creates two `/24` subnets in one available Availability Zone, creates/attaches an IGW, and creates public/private route tables. Only the public route table receives a default route. It also tags the VPC-generated default route table, default security group and default network ACL. Created IDs are saved in `infra/.state`, which is private and Git-ignored.

### Key AWS CLI options in this script

- `aws ec2 create-vpc --cidr-block 10.20.0.0/16`: creates an isolated IPv4 network. A CIDR is an address range in slash notation.
- `--tag-specifications "ResourceType=vpc,Tags=[...]"`: applies tags at creation. The syntax is AWS CLI shorthand: resource type followed by a list of `{Key=...,Value=...}` objects.
- `--query 'Vpc.VpcId'`: JMESPath extracts one field from the AWS response, so the variable stores only the ID.
- `--output text`: returns a text value that is easy to capture in Bash; `table` is for human display and `json` for structured output.
- `--enable-dns-support '{"Value":true}'` and `--enable-dns-hostnames`: enable DNS features required by many VPC workloads.
- `--cidr-block 10.20.1.0/24` / `10.20.2.0/24`: creates public/private IP ranges inside the `10.20.0.0/16` VPC without overlap.
- `--availability-zone "$AZ"`: keeps the training environment in one AZ to keep the topology simple; production availability designs generally use more than one AZ.
- `modify-subnet-attribute --map-public-ip-on-launch`: configures automatic public IPv4 assignment for instances launched in the public subnet. The compute script also explicitly requests a public IP for the web host.
- `create-internet-gateway` / `attach-internet-gateway`: creates and attaches the VPC's internet gateway. The IGW alone doesn't make a subnet public; a route table must point to it and an instance needs public addressing/security-group rules.
- `create-route-table`, `create-route --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID"`: creates a table and a default IPv4 route through the IGW. `0.0.0.0/0` means any IPv4 destination not matched by a more-specific route.
- `associate-route-table`: associates a subnet with a route table. The script records the association ID for audit/cleanup.
- `describe-* --filters "Name=vpc-id,Values=$VPC_ID"`: narrows a list response to resources belonging to the project VPC. `--query` projects only columns needed for inspection.

The private route table intentionally has no default internet route yet. The state file contains IDs, not secret values. Do not commit it because it contains live infrastructure identifiers.

## 5. Create security and identities — `infra/02-security.sh`

Set `STUDENT_CIDR` in the same terminal and run:

```bash
export STUDENT_CIDR="YOUR_CURRENT_PUBLIC_IPV4/32"
./infra/02-security.sh
```

### Security-group rules

- Web SG inbound `TCP/80` from `0.0.0.0/0`: public HTTP only.
- Web SG inbound `TCP/22` from `STUDENT_CIDR`: SSH from one student IPv4 only. This is a temporary lab access method; keep the CIDR current. Do not use `0.0.0.0/0` for SSH.
- DB SG inbound `TCP/3306` with `--source-group "$WEB_SG"`: MySQL is permitted only from interfaces associated with the web SG. It is more resilient than allowing an IP range when web IPs change.
- No inbound port 3306 from the internet; DB instance launch uses `--no-associate-public-ip-address` in the private subnet.
- Security groups are stateful: reply traffic for permitted connections is automatically allowed. Default outbound rules allow package/API traffic for this lab; tighten them further in a production environment after enumerating needed egress.

### Why three identities

1. `webstack-admin` is a human IAM user in `webstack-admins`. The group receives `AdministratorAccess` plus a customer-managed deny policy that blocks normal actions when MFA is absent but permits MFA enrollment actions. The script does not create a console password or access keys. After `infra/02-security.sh`, an account administrator opens **IAM Console → Users → webstack-admin → Security credentials**, enables console access/creates an initial password securely, and shares it only through the approved password-delivery process. Repeat console-access setup for `webstack-auditor` if you need to demonstrate read-only login. Sign in as `webstack-admin`, use **Security credentials → Assign MFA device** to enroll an authenticator, and confirm its state is enabled. Test normal administrative actions only with an MFA-authenticated session. Never put a password or MFA seed in a script or commit it to the repository.
2. `webstack-auditor` is in `webstack-auditors`, which receives AWS managed `ReadOnlyAccess` plus an explicit deny policy blocking `ssm:GetParameter*`. It can inspect resources but cannot retrieve parameter values, including through history/path APIs. The managed policy is broad account-wide read-only access; use a narrower custom policy for a real enterprise audit role.
3. `webstack-ec2-role` is trusted only by the EC2 service through `iam/trust-policy.json`. Its one attached custom policy allows `ssm:GetParameter` on exactly `arn:aws:ssm:REGION:ACCOUNT_ID:parameter/webstack/db-password` (the script fills in the selected region and account ID at runtime). It does not grant `PutParameter`, other SSM reads, administrator access or Session Manager features.

The template policy contains `123456789012` and `us-east-1` as **placeholders/default template values only**. The script replaces them with the caller's account ID and selected `REGION` in a private temporary file before creating the policy. No actual account ID is committed. Parameter Store uses `SecureString`; the password is generated with `openssl rand -hex 24`, written through a mode-600 temporary JSON document, and never printed or saved in `.state`.

### Relevant IAM/SSM syntax

- `Principal.Service = ec2.amazonaws.com` in the trust policy means EC2 can assume the role. A trust policy answers **who can assume** a role; a permissions policy answers **what the assumed role can do**.
- `Action: ssm:GetParameter` plus one `Resource` ARN follows least privilege: the workload can retrieve exactly one parameter.
- `aws sts get-caller-identity --query Account --output text` discovers the account ID for ARN construction; it avoids hard-coding the real ID.
- `create-policy --policy-document file://...` creates a managed customer policy; `attach-role-policy` attaches it to the EC2 role. `create-instance-profile` and `add-role-to-instance-profile` make the role attachable to EC2.
- `put-parameter` with `Type: SecureString` asks SSM Parameter Store to store an encrypted string. `GetParameter --with-decryption` returns a decrypted value only to a principal allowed to retrieve it.
- The user/group script makes identities and policy groups but does not add long-lived access keys. Do not call `aws iam create-access-key` for these users.

## 6. Prepare and scan the repository

The web user-data script clones a public GitHub repo's `main` branch. Therefore the repository must contain these exact files before the EC2 launch:

```text
app/app.py
app/requirements.txt
deploy/systemd/webstack.service
deploy/nginx/webstack.conf
deploy/db-userdata.sh
deploy/web-userdata.sh
```

Create an **empty public GitHub repository** (do not ask GitHub to generate a README/license because this folder already contains them), then from the root of this folder run:

```bash
git init -b main
./scripts/secret_scan.sh
git add .gitignore README.md infra iam budget app deploy scripts docs teardown.sh
git status --short
git commit -m "Add secure AWS deployment lab"
git remote add origin "https://github.com/YOUR_GITHUB_OWNER/YOUR_PUBLIC_REPO.git"
git push -u origin main
```

Replace both GitHub placeholders before running `git remote add`. Authenticate using your approved GitHub sign-in; do not embed a GitHub token in the remote URL. If a remote already exists, inspect `git remote -v` rather than adding a second `origin`.

The web user-data script clones the public repo's `main` branch, so every file needed by bootstrap must be committed and pushed **before** launching the EC2 instances. Run the scan again after edits and before commits:

```bash
./scripts/secret_scan.sh
git status --short
```

The scanner checks common high-confidence AWS access-key/private-key patterns and disallowed local files. A scanner is a guardrail, not proof that the repository is secret-free. Inspect diffs manually, review Git history, and rotate any credential that was ever committed—removing it from the latest commit alone does not make it safe.

`.gitignore` blocks `*.pem`, rendered user data, `.env` files and `infra/.state`. Git ignores only prevent new untracked files being added; they do not remove files already tracked. Check with `git ls-files` if you previously committed a key.

## 7. Launch database then web — `infra/03-compute.sh`

Set the actual public HTTPS repo URL and run:

```bash
export REPO_URL="https://github.com/YOUR_GITHUB_OWNER/YOUR_PUBLIC_REPO.git"
./infra/03-compute.sh
```

The script does the following in order:

1. Resolves the current Ubuntu 24.04 AMD64 AMI using a public SSM parameter.
2. Creates a tagged EC2 key pair. AWS returns the private half only once; the script writes it to `~/.ssh/webstack-key.pem` under a restrictive umask and changes permission to `400`. Do not commit this file.
3. Allocates a tagged Elastic IP and creates a tagged NAT Gateway in the public subnet.
4. Waits for NAT availability, then temporarily adds `0.0.0.0/0` via NAT to the private route table.
5. Renders `db-userdata.sh` with the selected region and launches the database in the private subnet **without a public IPv4 address**.
6. Waits for EC2 state and status checks, then captures the private IP.
7. Renders web user data with region, database private IP and repository URL, launches the web instance with a public IPv4 address, and waits for status checks.
8. Polls `http://WEB_PUBLIC_IP/db`. This is an end-to-end gate: it should return JSON containing `database=connected`, proving the app can authenticate and execute a query against MySQL through the private path.
9. Only after that check succeeds, the script deletes the temporary private default route, deletes the NAT Gateway, waits for deletion, and releases the temporary Elastic IP. If the readiness check fails, it intentionally leaves the NAT route/Gateway for diagnosis and prints a warning. You must explicitly clean it up later.

### Meaning of the key `run-instances` options

- `--region "$REGION"`: selects the AWS Region for the API request.
- `--image-id "$AMI_ID"`: chooses the Ubuntu 24.04 AMI. The AMI parameter is resolved at runtime, so no region-specific AMI ID is hard-coded.
- `--instance-type t3.micro`: chooses a small burstable instance. Size and eligibility/cost depend on your account/region; check pricing and quotas before use.
- `--count 1`: request one instance.
- `--key-name webstack-key`: associates the EC2 key pair for SSH. The DB has no public IP and its SG has no inbound SSH rule by default; the key is primarily useful for the public web host and an approved temporary diagnostic path.
- `--subnet-id "$PRIV_SUBNET"` / `--subnet-id "$PUB_SUBNET"`: chooses the correct subnet. The subnet and security groups must belong to the same VPC.
- `--security-group-ids "$DB_SG"` / `"$WEB_SG"`: applies the tier's firewall policy. These are shell-variable expansions, not literal strings.
- `--no-associate-public-ip-address`: prevents automatic public IPv4 assignment to DB. `--associate-public-ip-address` requests a public IPv4 address for the web server.
- `--iam-instance-profile "Name=$INSTANCE_PROFILE"`: supplies temporary role credentials through instance metadata; it avoids static AWS keys in user-data.
- `--metadata-options 'HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=1'`: requires IMDSv2 tokens and enables the metadata endpoint with hop limit one.
- `--user-data file://...`: passes a shell script to cloud-init. User-data scripts generally run at first boot as root; they are not a secret store. Never put credentials in the script.
- `--tag-specifications`: applies `Project`, `Owner` and `Name` tags at creation. The compute script tags instance, EBS volume and primary network interface resources.
- `--query 'Instances[0].InstanceId' --output text`: extracts the new instance ID without dumping the full response.
- `aws ec2 wait instance-running` / `instance-status-ok`: CLI waiters poll AWS until instance state or status checks meet the waiter's success condition. They do **not** guarantee that user-data is finished, so the final `/db` poll is still necessary.
- `sed -e 's|__DB_PRIVATE_IP__|...|g'`: substitutes a non-secret deployment value into a template. Rendered scripts are ignored by Git; inspect them before use and delete them at teardown.
- `curl -fsS --max-time 6 URL`: fails on HTTP error responses (`-f`), stays quiet except errors (`-sS`), and times out a single attempt after six seconds. The loop retries because cloud-init may still be working.

### Additional AWS CLI flag reference

The scripts use the same command-line conventions repeatedly. The following reference covers the meaningful flags that appear across the networking, security, launch, budget and teardown scripts.

| Flag or syntax | Meaning in this lab |
|---|---|
| `--region "$REGION"` | Selects the Region for a regional service call. IAM is global; Budgets commands in this template use `us-east-1`. |
| `--vpc-id "$VPC_ID"` | Tells AWS which VPC owns a subnet, route table, security group, or gateway. Related resources must be in compatible VPCs. |
| `--subnet-id "$PUB_SUBNET"` / `"$PRIV_SUBNET"` | Selects where the EC2 instance or NAT Gateway is placed. The database uses the private subnet; the web instance and NAT Gateway use the public subnet. |
| `--route-table-id "$PRIV_RT"` | Identifies the route table whose default route is temporarily changed during DB provisioning. |
| `--destination-cidr-block 0.0.0.0/0` | Defines the IPv4 default route: destinations not covered by a more-specific route. It is not an inbound firewall rule. |
| `--gateway-id "$IGW_ID"` | Makes the public route target the Internet Gateway. |
| `--nat-gateway-id "$NAT_ID"` | Makes the temporary private default route target the NAT Gateway. |
| `--protocol tcp --port 3306 --source-group "$WEB_SG"` | Allows MySQL TCP connections from ENIs attached to the web security group; no world-open database port. |
| `--protocol tcp --port 80 --cidr 0.0.0.0/0` | Allows HTTP from any IPv4 address, satisfying the project's public HTTP rule. |
| `--protocol tcp --port 22 --cidr "$STUDENT_CIDR"` | Allows SSH only from the student's IPv4 `/32`. Never replace this with `0.0.0.0/0`. |
| `--tag-specifications "ResourceType=...,Tags=[...]"` | Applies tags as a resource is created. The command uses AWS CLI shorthand syntax; commas separate fields and braces represent each tag object. |
| `--tags "Key=Project,Value=webstack" "Key=Owner,Value=$OWNER"` | Applies tags through IAM APIs that use a `--tags` list rather than EC2 tag specifications. |
| `--filters "Name=vpc-id,Values=$VPC_ID"` | Server-side filtering narrows a describe/list response before it is returned. Multiple filters are usually combined with AND; multiple values for one filter are alternatives. |
| `--query 'Instances[0].InstanceId'` | Uses JMESPath to extract only the field needed from the JSON response. Array index `[0]` selects the first result. |
| `--output text` / `json` / `table` | `text` is useful for shell variables, `json` for structured inspection or further processing, and `table` for human-readable terminal output. Don't parse a decorative table in scripts. |
| `--iam-instance-profile "Name=$INSTANCE_PROFILE"` | Attaches an IAM instance profile to EC2 so workloads receive temporary role credentials from instance metadata, not static AWS keys. |
| `--metadata-options 'HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=1'` | Requires IMDSv2 tokens and limits metadata response hops to one, a defensive default for this single-host lab. |
| `--user-data "file://path/to/script.sh"` | Sends the local file contents as EC2 user data; cloud-init runs it during first boot. `file://` is a local-file reference, not a URL or a secret vault. |
| `--no-associate-public-ip-address` | Explicitly prevents the DB instance from receiving an auto-assigned public IPv4 address at launch. |
| `--key-name webstack-key` | Associates the EC2 public key. AWS returns the corresponding private key material only when the key pair is created; the script stores it locally with restrictive permissions. |
| `--policy-document "file://...json"` | Supplies an IAM permissions policy document to create-policy. |
| `--assume-role-policy-document "file://...json"` | Supplies the role trust policy: who is allowed to assume the role. It does not itself grant SSM permissions. |
| `--policy-arn "$READ_POLICY_ARN"` | Identifies a customer- or AWS-managed IAM policy for attachment/detachment. |
| `--name "/webstack/db-password" --with-decryption` | `--name` picks the exact parameter; `--with-decryption` asks Parameter Store to return the plaintext value to the authorized process. Never display or log the result. |
| `--account-id "$ACCOUNT_ID" --budget file://budget.json` | Identifies the billing account and supplies the budget configuration file to AWS Budgets. |
| `--notifications-with-subscribers file://...json` | Defines the alert thresholds and email subscribers. Email recipients must complete AWS verification. |
| `--resource-tags "Key=Project,Value=webstack" ...` | Tags the budget itself; budget tags use a different CLI option than EC2 resources. |
| `aws ec2 wait ...` | Uses an AWS CLI waiter to poll until a named resource state is reached. `instance-running` alone does not mean user data has finished; the later HTTP readiness loop is required. |
| `aws ec2 delete-*`, `aws iam delete-*`, `aws ssm delete-parameter` | Destructive operations. The teardown script requires an explicit confirmation token and uses saved IDs; inspect every deletion before running in a non-lab account. |

### Common shell patterns used by the scripts

```bash
VALUE="$(command --query 'Field' --output text)"
```

`$(...)` runs the command in a subshell and captures stdout; quoting the substitution preserves a single value as one argument. If the command's output can include secrets, don't print the resulting variable.

```bash
if ! command; then
  echo "operation failed" >&2
  exit 1
fi
```

`!` reverses the exit status for the `if`; `>&2` sends the message to standard error; `exit 1` returns a non-zero script status to the caller.

```bash
for ID in $IDS; do
  command --resource-id "$ID"
done
```

This iterates over a whitespace-separated list of IDs from AWS CLI `--output text`. IDs themselves contain no whitespace. When handling arbitrary strings, prefer Bash arrays rather than word splitting.

```bash
aws ... || true
```

This suppresses failure for an intentionally optional cleanup check; it should not be used indiscriminately. In the teardown script, each use is narrowly scoped to resources that may already have been removed by a previous partial cleanup.

```bash
trap 'rc=$?; echo "failed near line ${LINENO} (exit ${rc})" >&2; exit "$rc"' ERR
```

`trap` registers an error handler, `$?` captures the failing status, and `${LINENO}` reports the line location. The handler intentionally does not print environment variables or secret values.

### Database user-data behavior

`deploy/db-userdata.sh` installs MySQL and the prerequisites for the official AWS CLI v2 installer, reads `/webstack/db-password` from SSM, validates the expected 48 hexadecimal characters, then configures MySQL. The config is named `zz-webstack.cnf` so it loads after the stock `mysqld.cnf` setting. It listens on IPv4 interfaces (`0.0.0.0:3306`), but the DB security group allows MySQL only from the web SG. Network binding is not a firewall; both settings matter.

The script creates `webstack_db`, the account `webstack_app` restricted to source host `10.20.1.%`, and a minimal `SELECT` grant for the `/db` health query. It never writes the password into the repository or logs. If the actual student application requires more database actions, add only the required grants and document why.

### Web user-data behavior

`deploy/web-userdata.sh` downloads the public code, verifies expected files, creates `/opt/webstack/venv`, installs the pinned requirements, retrieves the same parameter through the role, and writes `/etc/webstack/webstack.env` with mode `600`. The environment file has the variables the sample Flask app actually reads: `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD` and `DB_NAME`.

It installs the systemd unit and Nginx site, runs `nginx -t`, reloads systemd and starts the services. `User=webstack`, `Group=www-data`, and `UMask=0007` let Gunicorn create a Unix socket that the Nginx worker can access without making the socket world-writable. `NoNewPrivileges=true` prevents the service process from gaining new privileges, and `PrivateTmp=true` gives it a private `/tmp` namespace.

## 8. Verify functionality and governance

### Runtime tests

```bash
# Use the instance IDs printed by 03-compute.sh, or read them from infra/.state.
source infra/.state
aws ec2 describe-instances --region "$REGION" --instance-ids "$DB_ID" "$WEB_ID" \
  --query 'Reservations[].Instances[].[InstanceId,State.Name,PrivateIpAddress,PublicIpAddress,SubnetId,SecurityGroups[].GroupId]' \
  --output table

curl -i "http://${WEB_IP}/health"
curl -i "http://${WEB_IP}/db"
```

Expected `/health`: HTTP 200 with `status=ok`. Expected `/db`: HTTP 200 with `database=connected`. The DB instance's public IP should be `None`/empty. In the private route table after the compute script completes, there should be no `0.0.0.0/0` route.

### IAM least-privilege proof

```bash
source infra/.state
aws iam list-attached-role-policies --role-name "$IAM_ROLE" --output table
aws iam get-policy --policy-arn "$READ_POLICY_ARN"
aws iam get-policy-version --policy-arn "$READ_POLICY_ARN" --version-id v1
aws iam list-groups-for-user --user-name "$ADMIN_USER"
aws iam list-groups-for-user --user-name "$AUDITOR_USER"
```

The customer-managed role policy must grant only `ssm:GetParameter` on one ARN ending in `parameter/webstack/db-password`. Do not use `get-parameter --with-decryption` to collect evidence. `describe-parameters` can show the parameter exists without disclosing the value.

### Network proof

```bash
aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$PUB_RT" "$PRIV_RT" \
  --query 'RouteTables[].{Table:RouteTableId,Associations:Associations[].SubnetId,Routes:Routes[].{Destination:DestinationCidrBlock,Gateway:GatewayId,NAT:NatGatewayId}}' \
  --output json
aws ec2 describe-security-groups --region "$REGION" --group-ids "$WEB_SG" "$DB_SG" --output json
```

After successful deployment, the public table routes to the IGW; the private table has only the local route. The DB SG has TCP/3306 from `WEB_SG` only. Web SG has TCP/80 open to IPv4 world and TCP/22 from the student's single `/32` only.

## 9. Teardown

Capture evidence **before** running teardown. The script asks for `DELETE-WEBSTACK`, terminates tracked instances, waits for termination, deletes the endpoint/NAT dependencies it can find in the dedicated VPC, releases temporary EIPs, removes subnets/security groups/custom routes/IGW/VPC, deletes the SSH key pair, parameter, IAM role/profile/policies/users/groups, and the monthly budget. It optionally asks whether to delete the local private key.

```bash
./teardown.sh
```

If it stops with a dependency error, don't force-delete an ENI. Inspect it with:

```bash
aws ec2 describe-network-interfaces --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,State:Status,Description:Description,Type:InterfaceType,Subnet:SubnetId,Instance:Attachment.InstanceId,Managed:RequesterManaged}' \
  --output table
```

Remove the owning resource (for example, an EC2 Instance Connect Endpoint) and retry. The teardown script uses `.state` to avoid guessing IDs, and exits if a subnet still has dependencies. Review it before running; it is intentionally destructive.
