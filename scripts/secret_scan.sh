#!/usr/bin/env bash
# Lightweight guardrail against common AWS keys/private keys and credential files.
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
command -v git >/dev/null || { echo "git is required for secret_scan.sh" >&2; exit 2; }

status=0
if grep -RInE \
  --exclude-dir=.git \
  --exclude-dir=.venv \
  --exclude-dir=venv \
  --exclude='*.pem' \
  --exclude='*.rendered.sh' \
  --exclude='.state' \
  'AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----|aws_secret_access_key[[:space:]]*=[[:space:]]*[^[:space:]]+' \
  .; then
  echo "ERROR: possible credential material found; inspect matches and rotate any exposed key." >&2
  status=1
fi

forbidden_files="$(find . -type f \( -name '*.pem' -o -name 'credentials' -o -name 'aws-credentials' -o -name '.env' -o -name '.env.*' \) -not -path './.git/*' -print)"
if [[ -n "$forbidden_files" ]]; then
  echo "ERROR: credential/local-generated files found in the working tree:" >&2
  printf '%s\n' "$forbidden_files" >&2
  echo "Remove them or ensure they are ignored and never committed." >&2
  status=1
fi

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  tracked_forbidden="$(git ls-files | grep -E '(^|/)([^/]*\.pem|[^/]*\.rendered\.sh|credentials|aws-credentials|\.env|\.env\..*)$' || true)"
  if [[ -n "$tracked_forbidden" ]]; then
    echo "ERROR: sensitive/generated paths are tracked by Git:" >&2
    printf '%s\n' "$tracked_forbidden" >&2
    status=1
  fi
else
  echo "NOTICE: repository is not yet initialized with Git; file-content scan still ran." >&2
fi

if [[ "$status" -eq 0 ]]; then
  echo "Secret scan passed the configured high-confidence checks. This is not a substitute for a full secret scanner or human review."
fi
exit "$status"
