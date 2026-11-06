#!/usr/bin/env bash
# Configure the repository for the autonomous agent loop:
# secrets, variables, labels, merge settings, and branch protection.
#
# Usage:
#   scripts/bootstrap.sh <owner/repo> <test_cmd> [--require-human-approval]
#
# Required environment:
#   APP_ID                  numeric GitHub App id
#   APP_PRIVATE_KEY_FILE    path to the App's .pem private key
#   ANTHROPIC_API_KEY       value, OR provide ./api-key.txt (first line used)
#
# Optional environment (defaults in brackets):
#   INSTALL_CMD   [pip install pytest]
#   LINT_CMD      [true]
#   AGENT_MODEL   [claude-sonnet-4-6]
#   REVIEW_MODEL  [claude-opus-4-7]
#   MAX_FIX_ROUNDS [3]
#
# The script never echoes secret values. API key and PEM are piped on stdin.
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: scripts/bootstrap.sh <owner/repo> <test_cmd> [--require-human-approval]" >&2
  exit 2
fi

REPO="$1"
TEST_CMD="$2"
shift 2
REQUIRE_HUMAN_APPROVAL=0
for arg in "$@"; do
  case "$arg" in
    --require-human-approval) REQUIRE_HUMAN_APPROVAL=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

: "${APP_ID:?APP_ID is required}"
: "${APP_PRIVATE_KEY_FILE:?APP_PRIVATE_KEY_FILE is required}"
if [ ! -f "$APP_PRIVATE_KEY_FILE" ]; then
  echo "APP_PRIVATE_KEY_FILE does not exist: $APP_PRIVATE_KEY_FILE" >&2
  exit 2
fi

INSTALL_CMD="${INSTALL_CMD:-pip install pytest}"
LINT_CMD="${LINT_CMD:-true}"
AGENT_MODEL="${AGENT_MODEL:-claude-sonnet-4-6}"
REVIEW_MODEL="${REVIEW_MODEL:-claude-opus-4-7}"
MAX_FIX_ROUNDS="${MAX_FIX_ROUNDS:-3}"

# Resolve API key source without echoing it.
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  if [ -f ./api-key.txt ]; then
    API_KEY_SRC="file:./api-key.txt"
  else
    echo "ANTHROPIC_API_KEY not set and ./api-key.txt missing" >&2
    exit 2
  fi
else
  API_KEY_SRC="env"
fi

echo "repo:           $REPO"
echo "test_cmd:       $TEST_CMD"
echo "install_cmd:    $INSTALL_CMD"
echo "lint_cmd:       $LINT_CMD"
echo "agent_model:    $AGENT_MODEL"
echo "review_model:   $REVIEW_MODEL"
echo "max_fix_rounds: $MAX_FIX_ROUNDS"
echo "api_key_src:    $API_KEY_SRC"
echo "pem_file:       $APP_PRIVATE_KEY_FILE"
echo "require_human:  $REQUIRE_HUMAN_APPROVAL"
echo

# Preflight: gh auth, admin, public-ness.
echo "preflight..."
gh auth status >/dev/null
perm=$(gh repo view "$REPO" --json viewerPermission -q .viewerPermission)
if [ "$perm" != "ADMIN" ]; then
  echo "need ADMIN on $REPO, have $perm" >&2
  exit 1
fi
is_private=$(gh repo view "$REPO" --json isPrivate -q .isPrivate)
if [ "$is_private" = "true" ]; then
  echo "warning: repo is private; branch protection requires GitHub Pro or higher on personal accounts" >&2
fi

# Verify App install on the repo via JWT. Keeps us from writing bad secrets.
echo "verifying App installation..."
python3 - "$APP_ID" "$APP_PRIVATE_KEY_FILE" "$REPO" <<'PY'
import base64, json, subprocess, sys, time, urllib.request
app_id, pem_path, repo = sys.argv[1], sys.argv[2], sys.argv[3]
def b64url(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()
now = int(time.time())
header = b64url(json.dumps({"alg":"RS256","typ":"JWT"},separators=(",",":")).encode())
payload = b64url(json.dumps({"iat":now-60,"exp":now+540,"iss":int(app_id)},separators=(",",":")).encode())
signing_input = f"{header}.{payload}".encode()
sig = subprocess.check_output(["openssl","dgst","-sha256","-sign",pem_path],input=signing_input)
jwt = f"{header}.{payload}.{b64url(sig)}"
req = urllib.request.Request("https://api.github.com/app/installations",
    headers={"Authorization":f"Bearer {jwt}","Accept":"application/vnd.github+json"})
installs = json.loads(urllib.request.urlopen(req).read())
owner = repo.split("/")[0]
match = [i for i in installs if i["account"]["login"].lower()==owner.lower()]
if not match:
    print(f"no App installation found for {owner}", file=sys.stderr); sys.exit(1)
inst = match[0]
req = urllib.request.Request(f"https://api.github.com/app/installations/{inst['id']}/access_tokens",
    method="POST",
    headers={"Authorization":f"Bearer {jwt}","Accept":"application/vnd.github+json"})
tok = json.loads(urllib.request.urlopen(req).read())["token"]
req = urllib.request.Request("https://api.github.com/installation/repositories",
    headers={"Authorization":f"token {tok}","Accept":"application/vnd.github+json"})
repos = [r["full_name"] for r in json.loads(urllib.request.urlopen(req).read())["repositories"]]
if repo not in repos:
    print(f"App installed but {repo} not in selected repos: {repos}", file=sys.stderr); sys.exit(1)
required = {"contents":"write","issues":"write","pull_requests":"write","statuses":"write"}
missing = [k for k,v in required.items() if inst["permissions"].get(k)!=v]
if missing:
    print(f"App missing write perms on: {missing}", file=sys.stderr); sys.exit(1)
print(f"ok: installation {inst['id']} covers {repo} with required perms")
PY

# Secrets.
echo "setting secrets..."
if [ "$API_KEY_SRC" = "env" ]; then
  printf '%s' "$ANTHROPIC_API_KEY" | gh secret set ANTHROPIC_API_KEY --repo "$REPO"
else
  gh secret set ANTHROPIC_API_KEY --repo "$REPO" < ./api-key.txt
fi
printf '%s' "$APP_ID" | gh secret set APP_ID --repo "$REPO"
gh secret set APP_PRIVATE_KEY --repo "$REPO" < "$APP_PRIVATE_KEY_FILE"

# Variables.
echo "setting variables..."
gh variable set TEST_CMD        --repo "$REPO" --body "$TEST_CMD"
gh variable set INSTALL_CMD     --repo "$REPO" --body "$INSTALL_CMD"
gh variable set LINT_CMD        --repo "$REPO" --body "$LINT_CMD"
gh variable set AGENT_MODEL     --repo "$REPO" --body "$AGENT_MODEL"
gh variable set REVIEW_MODEL    --repo "$REPO" --body "$REVIEW_MODEL"
gh variable set MAX_FIX_ROUNDS  --repo "$REPO" --body "$MAX_FIX_ROUNDS"

# Labels. --force makes this idempotent.
echo "creating labels..."
gh label create agent-task     --repo "$REPO" --color "0e8a16" --description "Start the agent loop on this issue" --force
gh label create agent          --repo "$REPO" --color "5319e7" --description "PR owned by the agent loop" --force
gh label create agent-round-1  --repo "$REPO" --color "fbca04" --description "Fix round 1 attempted" --force
gh label create agent-round-2  --repo "$REPO" --color "fbca04" --description "Fix round 2 attempted" --force
gh label create agent-round-3  --repo "$REPO" --color "fbca04" --description "Fix round 3 attempted" --force
gh label create needs-human    --repo "$REPO" --color "b60205" --description "Loop stopped; a person takes over" --force

# Merge settings.
echo "configuring merge settings..."
gh repo edit "$REPO" --enable-auto-merge --delete-branch-on-merge

# Branch protection.
echo "setting branch protection on main..."
if [ "$REQUIRE_HUMAN_APPROVAL" -eq 1 ]; then
  reviews='{"required_approving_review_count":1,"dismiss_stale_reviews":true,"require_code_owner_reviews":false}'
else
  reviews='null'
fi
cat >/tmp/bp.json <<JSON
{
  "required_status_checks": { "strict": false, "contexts": ["test","claude-review"] },
  "enforce_admins": true,
  "required_pull_request_reviews": $reviews,
  "restrictions": null,
  "required_linear_history": false,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": true
}
JSON
gh api -X PUT "repos/$REPO/branches/main/protection" --input /tmp/bp.json >/dev/null
rm -f /tmp/bp.json

echo
echo "done."
