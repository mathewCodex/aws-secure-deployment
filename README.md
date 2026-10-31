# Secure AWS Cloud Deployment — Weekly Hands-On Project

A reproducible, auditable AWS CLI lab for a small Flask + MySQL application. The learning goal is professional cloud hygiene: network separation, least-privilege identities, a `SecureString` secret, MFA enforcement, active budget notifications, tagging, secret scanning, evidence and teardown.

> **Cost/destructive-action warning:** these scripts create real AWS resources. NAT Gateways, public IPv4 addresses, EC2/EBS usage, data transfer and related resources can cost money. `teardown.sh` is destructive. Use a learning account, select the correct profile/account, capture evidence before teardown, and never run the teardown script against a shared VPC.

## Read first

- [Complete all-in-one guide](GUIDE.md)
- [Step-by-step guide and syntax reference](docs/STEP-BY-STEP.md)
- [Architecture](docs/ARCHITECTURE.md)
- [IAM design](docs/IAM-DESIGN.md)
- [Cost governance and proof](docs/COST-GOVERNANCE.md)
- [Failure runbook](docs/RUNBOOK.md)
- [Evidence checklist](docs/evidence/README.md)

## Repository map

```text
aws-secure-deployment/
├── README.md
├── GUIDE.md                         # all-in-one step-by-step and syntax guide
├── infra/01-network.sh              # VPC, subnets, IGW and route tables
├── infra/02-security.sh             # SGs, SecureString, least-privilege IAM
├── infra/03-compute.sh              # temporary NAT, key pair, DB then web launch
├── teardown.sh                      # destructive dependency-aware cleanup
├── iam/                             # trust, permissions, MFA and auditor-deny policies
├── budget/                          # monthly budget, 80% actual / 100% forecast alerts
├── app/                             # Flask health and DB-check endpoints
├── deploy/                          # first-boot scripts, systemd and Nginx configs
├── scripts/secret_scan.sh           # high-confidence local secret checks
└── docs/                             # architecture, IAM, costs, runbook and evidence
```

## Execution order

1. Prepare AWS CLI credentials through your approved login method (prefer AWS IAM Identity Center/temporary credentials; do not create long-lived access keys for this lab).
2. Set `REGION`, `OWNER`, `STUDENT_CIDR`, and a real `BUDGET_EMAIL`. Create the budget first and verify its email recipient.
3. Publish this repository to a **public GitHub repository** with the `main` branch. Do not include `.state`, `.pem`, rendered user-data, credentials or `.env` files.
4. Run `infra/01-network.sh`.
5. Run `infra/02-security.sh`, then enable console access and MFA for the admin user using the IAM Console.
6. Run `scripts/secret_scan.sh` before pushing code, and again before gathering evidence.
7. Export `REPO_URL` and run `infra/03-compute.sh`. It creates a temporary NAT route only for database provisioning; on successful end-to-end `/db` check, it removes the private default route, NAT Gateway and temporary Elastic IP.
8. Verify governance evidence and the email verification state. Forecasted alerts may not produce an alert until AWS has adequate historical cost data.
9. Save sanitized evidence. Then run `./teardown.sh` and verify residual resources.

All numbered scripts assume a dedicated learning account/VPC. They intentionally stop rather than blindly overwrite an existing `infra/.state`. Do not repeatedly run `create-*` commands after partial failure without inspecting the state file and AWS resources.

## Example configuration (replace values)

```bash
export REGION=us-east-1
export OWNER=student01
export STUDENT_CIDR="YOUR_CURRENT_PUBLIC_IPV4/32"
export BUDGET_EMAIL="you@your-real-domain.example"
```

Find the public IPv4 address from a trusted source or network details, then use `/32` to allow only that address to SSH to the web server. The example above is a template, not a usable address. If your address changes, update the security-group rule before reconnecting.

Create the monthly budget before deploying:

```bash
./budget/create-budget.sh
```

Create the network and security:

```bash
./infra/01-network.sh
./infra/02-security.sh
```

Push the repo to GitHub `main`, then set the URL and launch:

```bash
export REPO_URL="https://github.com/YOUR_GITHUB_OWNER/YOUR_PUBLIC_REPO.git"
./scripts/secret_scan.sh
git status --short
./infra/03-compute.sh
```

Do not leave `YOUR_GITHUB_OWNER` or `YOUR_PUBLIC_REPO` in the command; replace both with the actual public repo. A private repository needs a different authentication approach; never embed a GitHub token in user data.

## Important behaviors

- Database subnet: `10.20.2.0/24`; no public IP and no permanent default internet route.
- Web subnet: `10.20.1.0/24`; public IPv4 and route to an Internet Gateway.
- Web security group: TCP/80 from `0.0.0.0/0`; TCP/22 only from `STUDENT_CIDR` (`/32`). No public TCP/443 is configured because this exercise is HTTP-only; add TLS before production.
- Database security group: TCP/3306 only from the web security group.
- MySQL application account: source-host restriction `10.20.1.%`, matching the web subnet. It receives `SELECT` on `webstack_db` for the included health probe only; grant additional permissions only if the actual application requires them.
- Temporary NAT: used to bootstrap packages and retrieve the secret from the private database instance, then removed automatically only after `http://WEB_PUBLIC_IP/db` returns a connected result. If readiness fails, the script leaves the NAT in place for diagnosis and reports that cleanup is still needed.
- IAM instance profile: only `ssm:GetParameter` for `/webstack/db-password`. It does not include Systems Manager Session Manager permissions.
- Budget: account-wide USD $10/month template. Change the amount if needed. A budget is an alerting tool, not a spending cap.

## Cleanup

Capture evidence before teardown because the teardown also deletes the project budget, parameter, IAM users/groups, policies, key pair, instances and networking. Run `./teardown.sh`, type `DELETE-WEBSTACK` at the prompt, and then follow [the cleanup proof](docs/COST-GOVERNANCE.md).
