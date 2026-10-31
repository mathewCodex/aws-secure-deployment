#!/usr/bin/env bash
set -Eeou pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
REGION="${REGION:-us-east-1}"
OWNER="${OWNER:-}"
BUDGET_EMAIL="${BUDGET_EMAIL:-}"
echo "$ROOT_DIR"
if [[ -z "$BUDGET_EMAIL" || "$BUDGET_EMAIL" == "you@example.com" || "$BUDGET_EMAIL" != *@*.* ]]; then
	echo "set $BUDGET_EMAIL to a real inbox you can check. Do not commit it to the repo." >&2
	exit 2
fi
if [[ -z "$OWNER" || ! "$OWNER" =~ ^[A-Za-z0-9._-]{2,48}$ ]]; then
	echo "Set OWNER to a short tag Value, e.g. export OWNER=Codex01" >&2
	exit 2
fi
command -v jq >/dev/null || { echo "Install jq first." >&2; exit 2; }
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
[[ "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || { echo "Could not determine AWS Account ID." >&2; exit 1; }
BUDGET_STATE="$ROOT_DIR/budget/.state"
if [[ -e "$BUDGET_STATE" ]]; then
	echo "Budget state already exists at $BUDGET_STATE; inspect it before proceeding."  >&2
	exit 2
fi
if aws budgets describe-budget --region us-east-1 --acount-id "$ACCOUNT_ID" --budget-name webstack-monthly-budget >/dev/null 2>&1; then
	echo "A budget named webstack-monthly-budget already exists in this acoount . Refusing to overwrite or later delete it." >&2
	exit 2
fi
TMP_NOTIFICATIONS="$(mktemp)"
trap 'rm -f "$TMP_NOTIFICATIONS"' EXIT
jq --arg email "$BUDGET_EMAIL" \
  'map(.Subscribers |= map(if .SubscriptionType == "EMAIL" then .Address = $email else . end))' \
  "$ROOT_DIR/budget/notifications.json" \
  > "$TMP_NOTIFICATIONS"

jq -e 'type == "array" and length == 2' \
  "$TMP_NOTIFICATIONS" > /dev/null \
  || {
    echo "ERROR: Expected exactly two valid budget notifications."
    exit 1
  }

aws budgets create-budget \
  --region us-east-1 \
  --account-id "$ACCOUNT_ID" \
  --budget "file://$ROOT_DIR/budget/budget.json" \
  --notifications-with-subscribers "file://$TMP_NOTIFICATIONS" \
  --resource-tags "Key=Project,Value=webstack" "Key=Owner,Value=$OWNER"

printf 'ACCOUNT_ID=%q\nBUDGET_NAME=%q\n' "$ACCOUNT_ID" "webstack-monthly-budget" > "$BUDGET_STATE"
chmod 600 "$BUDGET_STATE"
echo "Created monthly budget. Check the notification recipient verification email and confirm it in AWS."
