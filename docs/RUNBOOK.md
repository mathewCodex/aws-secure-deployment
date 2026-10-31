# Runbook: common failures and evidence-led diagnosis

Each incident includes a symptom, likely cause, diagnostic command, safe fix and proof. Redact identifiers before sharing terminal output.

## 1. Database bootstrap cannot download packages or read SSM

**Symptoms:** `/var/log/db-userdata.log` stops during `apt-get`, AWS CLI download, or parameter retrieval. The web `/db` endpoint remains 503.

**Diagnose:**

```bash
aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$PRIV_RT" \
  --query 'RouteTables[0].Routes[].{Dest:DestinationCidrBlock,Gateway:GatewayId,NAT:NatGatewayId,State:State}' --output table
aws ec2 describe-nat-gateways --region "$REGION" --filter "Name=vpc-id,Values=$VPC_ID" \
  --query 'NatGateways[].[NatGatewayId,State,SubnetId]' --output table
```

During DB provisioning, private route `0.0.0.0/0` must target the temporary NAT Gateway, which must be in a public subnet whose route table reaches the IGW. Once `/db` is healthy, remove that route and NAT/EIP. Do not leave NAT behind after a failed readiness check. `AccessDeniedException` suggests role/policy/parameter ARN; a timeout suggests routing, DNS, endpoint or service reachability. Avoid printing `DB_PASS` while troubleshooting.

**Proof:** `apt-get update` succeeds; `aws ssm get-parameter` by the instance role can retrieve the SecureString in boot logic; `/db` returns 200; final private route table has no default route.

## 2. MySQL only listens on localhost

**Symptoms:** `ss -lntp | grep ':3306'` shows `127.0.0.1:3306`; web-server TCP test to DB private IP times out.

**Diagnose on DB:**

```bash
sudo grep -RniE 'bind-address|skip-networking' /etc/mysql/
sudo mysqld --print-defaults | tr ' ' '\n' | grep -- '--bind-address'
sudo systemctl status mysql --no-pager
sudo ss -lntp | grep ':3306'
```

**Fix:** ensure `/etc/mysql/mysql.conf.d/zz-webstack.cnf` contains `[mysqld]` and `bind-address = 0.0.0.0`; the `zz` filename makes it load after stock `mysqld.cnf`. Restart MySQL and re-check the listener. Binding to all IPv4 interfaces is safe only when the DB SG is strict; DB inbound must be TCP/3306 sourced from the web SG, never world-open.

**Proof:** listener is `0.0.0.0:3306` (or DB private IP); from web instance, `timeout 3 bash -c '</dev/tcp/DB_PRIVATE_IP/3306'` reports reachable; `/db` returns database connected.

## 3. Web instance cannot launch due VPC/security-group mismatch

**Symptoms:** EC2 returns `InvalidGroup.NotFound` or `Security group ... and subnet ... belong to different networks`.

**Diagnose:**

```bash
aws ec2 describe-subnets --region "$REGION" --subnet-ids "$PUB_SUBNET" \
  --query 'Subnets[0].[SubnetId,VpcId,CidrBlock]' --output table
aws ec2 describe-security-groups --region "$REGION" --group-ids "$WEB_SG" \
  --query 'SecurityGroups[0].[GroupId,VpcId,GroupName]' --output table
```

**Fix:** use a security group in the exact VPC that owns the subnet. Pass the variable expansion `"$WEB_SG"`, not literal text `"WEB_SG"`. The database and web subnets must share a VPC for the direct private routing design in this lab.

**Proof:** both describe commands return the same `VpcId`.

## 4. Gunicorn systemd service fails with `217/USER`

**Symptoms:** `systemctl status webstack` shows `status=217/USER` or “Failed to determine user credentials”.

**Diagnose:**

```bash
sudo systemctl cat webstack
getent passwd webstack
getent group www-data
```

**Fix:** `User=webstack` must exist, `Group=www-data` must exist, and the service's `WorkingDirectory` must match the actual application layout (`/opt/webstack` in this repository). Create the service account only if missing. Ensure `/opt/webstack` and the virtualenv are readable/executable by the service user.

**Proof:** `sudo systemctl is-active webstack` returns `active`; `sudo journalctl -u webstack -n 30 --no-pager` shows workers booting without 217/USER.

## 5. Gunicorn missing / requirements file empty

**Symptoms:** `.../venv/bin/gunicorn: No such file or directory`, or pip installs nothing.

**Diagnose:**

```bash
wc -c app/requirements.txt
find app -maxdepth 2 -type f -print
sudo /opt/webstack/venv/bin/python -m pip list
```

**Fix:** confirm `app/requirements.txt` in the GitHub `main` branch contains Flask, PyMySQL and Gunicorn dependencies and is non-empty. Commit/push the corrected source. The user-data script clones the default deployment branch at launch, so editing the source on the instance does not fix future deployments by itself. Recreate the venv only if its installation is incomplete, then reinstall with `/opt/webstack/venv/bin/python -m pip install -r /opt/webstack/requirements.txt`.

**Proof:** `gunicorn --version` from the venv works; `systemctl status webstack` is active; local socket health check returns 200.

## 6. MySQL TCP is reachable but application gets 503

**Symptoms:** `/health` returns 200 but `/db` returns 503.

**Diagnose:**

```bash
sudo cat /etc/webstack/webstack.env   # do NOT paste this output anywhere; it contains a password
sudo journalctl -u webstack -n 60 --no-pager
aws ec2 describe-security-groups --region "$REGION" --group-ids "$WEB_SG" "$DB_SG" --output json
```

Prefer to check the environment file's variable names without printing values:

```bash
sudo cut -d= -f1 /etc/webstack/webstack.env
```

**Likely causes:** wrong parameter value, application reads `DB_PASSWORD` but env file contains only `DATABASE_URL`, MySQL account host pattern doesn't match the web source IP (`10.20.1.%`), or DB password wasn't synchronized with SSM. The supplied bootstrap writes `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_NAME`; the SQL host is restricted to the web subnet.

**Fix:** synchronize the SSM SecureString and MySQL account only through an approved secure procedure; preserve the hex password validation; do not echo it. Keep database SG inbound to web SG only.

**Proof:** `/db` returns HTTP 200 and `database=connected`.

## 7. Budget email doesn't arrive

**Symptoms:** notification configuration exists but no email was received.

**Diagnose:** check the correct account/region and the AWS Budgets Console recipient status; inspect spam/junk; run `describe-notifications-for-budget`. Confirm the email address. AWS sends a recipient verification email to new addresses, and only verified addresses receive alerts.

**Important:** the verification email is not an 80% spend alert. Budget data is delayed; forecast notifications may need sufficient historical spend (AWS documentation describes roughly five weeks for forecasts in some scenarios). Preserve the verification proof, notification configuration proof and a real alert email if it is generated. Do not claim an alert fired solely because the JSON is configured.

## 8. Subnet/VPC deletion reports `DependencyViolation`

**Diagnose:**

```bash
aws ec2 describe-network-interfaces --region "$REGION" --filters "Name=subnet-id,Values=$PRIV_SUBNET" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,State:Status,Description:Description,Type:InterfaceType,Instance:Attachment.InstanceId,Managed:RequesterManaged}' --output table
aws ec2 describe-vpc-endpoints --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'VpcEndpoints[].[VpcEndpointId,VpcEndpointType,State,ServiceName,SubnetIds]' --output table
aws ec2 describe-instance-connect-endpoints --region "$REGION" \
  --query 'InstanceConnectEndpoints[].[InstanceConnectEndpointId,State,VpcId,SubnetId]' --output table
```

**Fix:** delete the owning resource (for example, an EC2 Instance Connect Endpoint or VPC endpoint), wait for AWS to remove its managed ENI, then delete the subnet. Never force-delete an in-use/requester-managed ENI. Check route table associations and NAT Gateways too.

**Proof:** no subnet/ENI/endpoint dependencies remain; subnet deletes; VPC deletion succeeds.
