# Evidence collection (keep this directory sanitized)

Capture evidence **before teardown**, then redact account IDs, personal emails, public IPs, usernames, serial numbers, secret values and other identifiers before storing or sharing it.

Suggested evidence set:

1. **Identity separation:** IAM users and group membership showing `webstack-admin` in `webstack-admins` and `webstack-auditor` in `webstack-auditors`; attached `AdministratorAccess` plus the `RequireMFA` deny policy for administrators; `ReadOnlyAccess` for auditors. Do not include access keys (none should be created).
2. **MFA:** console screenshot showing an MFA device enabled for the admin user. Do not show recovery codes or QR seeds.
3. **Instance role:** `aws iam get-role --role-name webstack-ec2-role`; `aws iam get-role-policy --role-name webstack-ec2-role --policy-name webstack-read-db-password`; policy resource should be only `/webstack/db-password`.
4. **SecureString:** `aws ssm describe-parameters --parameter-filters Key=Name,Option=Equals,Values=/webstack/db-password` (do not use `get-parameter --with-decryption` in evidence).
5. **Network:** route-table output showing public `0.0.0.0/0` to an IGW, private route table with no default internet route after deployment, no public IP on database, web SG port 80 from `0.0.0.0/0`, SSH only from a `/32`, and DB TCP/3306 from the web SG only.
6. **Application:** sanitized `curl` output for `/health` and `/db` returning 200/connected.
7. **Budget:** screenshot/output of `$10` monthly budget and both alert definitions (actual 80% and forecasted 100%). Save the recipient verification email and confirm its link. For strict grading, capture a real alert email if one is generated; a recipient-verification email alone proves address verification, not that a threshold alert has fired.
8. **No hard-coded keys:** run `scripts/secret_scan.sh` and include its sanitized successful output.
9. **Teardown proof:** after teardown, capture empty project-instance and available-NAT queries, no allocated project Elastic IP, and no project-specific VPC/network resources. Redact unrelated resources and account identifiers.

Never put credentials, private keys, decrypted Parameter Store output or full environment files in this directory.
