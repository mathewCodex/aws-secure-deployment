# IAM design and identity separation

## Identity matrix

| Identity | Scope | Permissions | What it must not do |
|---|---|---|---|
| `webstack-admin` in `webstack-admins` | Human admin | `AdministratorAccess` with a second policy that denies normal actions if MFA is absent | Normal admin actions without an MFA-backed session; no shared access keys |
| `webstack-auditor` in `webstack-auditors` | Human audit | AWS managed `ReadOnlyAccess` plus an explicit deny for `ssm:GetParameter*` | No write permissions and cannot retrieve parameter values; don't add it to the admin group |
| `webstack-ec2-role` attached through `webstack-ec2-profile` | EC2 workload | `ssm:GetParameter` on exactly `/webstack/db-password` in the selected account and region | No `PutParameter`, no broad `ssm:*`, no administrator rights, no static access keys |

This is an educational IAM-user implementation because the rubric explicitly asks for a group and MFA. For production, prefer centralized workforce access through IAM Identity Center and temporary credentials. AWS recommends temporary credentials, MFA and least privilege. See [AWS IAM security best practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html).

## Trust policy vs permissions policy

`iam/trust-policy.json` has `Principal.Service = ec2.amazonaws.com` and `Action = sts:AssumeRole`. It establishes that EC2 can assume the role. It does not grant SSM access by itself.

`iam/ssm-read-policy.json` grants exactly one action, `ssm:GetParameter`, on one parameter ARN. The account number in the tracked JSON is the required placeholder `123456789012`; the security script substitutes the real caller account ID and the selected `REGION` into a private temporary file before creating a tagged customer-managed policy. The actual account ID must not be committed to Git.

The parameter uses the AWS-managed Parameter Store key `aws/ssm`. If the lab is adapted to use a customer-managed KMS key, review and narrowly grant the required `kms:Decrypt` permission and key policy. Do not simply add `kms:Decrypt` on `*`.

Official reference: [Parameter Store IAM permissions](https://docs.aws.amazon.com/systems-manager/latest/userguide/parameter-store-setting-up.html).

## Administrator MFA policy

`iam/admin-mfa-policy.json` uses an explicit `Deny` with `NotAction` exceptions for MFA enrollment/session setup. The condition `BoolIfExists` on `aws:MultiFactorAuthPresent=false` blocks other administrative actions when MFA is absent. `AdministratorAccess` alone would not enforce MFA; the separate deny policy is the guardrail.

The script creates the user and group but intentionally does **not** create a console password or access key. In the IAM Console, an account administrator must enable console access/set the initial password securely and the user must enroll an MFA device. Confirm that MFA appears enabled. Never put a password or MFA seed in a script or commit it to the repository.

## Auditor boundary

The auditor is a separate user in a separate group with AWS managed `ReadOnlyAccess`, plus the customer-managed `webstack-auditor-deny-parameter-values` explicit deny. The deny blocks `ssm:GetParameter*` calls, including history and path-based retrieval, so the read-only identity cannot casually retrieve SecureString values. The managed policy is broad read-only access across AWS and may expose other metadata; enterprise roles should be narrower. The explicit deny wins over an Allow in `ReadOnlyAccess` because explicit Deny takes precedence.

## Verification commands

```bash
aws iam list-groups-for-user --user-name webstack-admin
aws iam list-groups-for-user --user-name webstack-auditor
aws iam list-attached-group-policies --group-name webstack-admins
aws iam list-attached-group-policies --group-name webstack-auditors
aws iam get-policy --policy-arn "$AUDITOR_POLICY_ARN"
aws iam get-policy-version --policy-arn "$AUDITOR_POLICY_ARN" --version-id v1
aws iam list-attached-role-policies --role-name webstack-ec2-role
aws iam get-policy --policy-arn "$READ_POLICY_ARN"
aws iam get-policy-version --policy-arn "$READ_POLICY_ARN" --version-id v1
aws ssm describe-parameters --parameter-filters Key=Name,Option=Equals,Values=/webstack/db-password
```

Expected results: admin belongs only to the admin group and has the MFA deny policy; auditor belongs only to the auditor group and has the explicit parameter-value deny; workload role has only the custom single-parameter policy; parameter metadata reports `SecureString`. Do not run a decrypted get-parameter command for evidence or paste its output into chat.

## MFA and access keys

This lab creates no IAM user access keys. The operator CLI itself should use AWS SSO/Identity Center or another approved temporary-credential mechanism. The EC2 instance profile provides temporary credentials through instance metadata and rotates them; the app does not need static AWS access keys.
