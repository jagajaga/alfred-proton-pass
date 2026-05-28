#!/bin/bash
# Build a JSON cache of all items across all vaults.
# Output: ${alfred_workflow_cache:-./cache}/index.json
#
# Usage:
#   index.sh           # refresh if cache is missing or older than TTL
#   index.sh --force   # refresh unconditionally

set -euo pipefail

PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

CACHE_DIR="${alfred_workflow_cache:-$(dirname "$0")/../cache}"
CACHE_FILE="$CACHE_DIR/index.json"
LOCK_FILE="$CACHE_DIR/index.lock"
TTL="${PP_CACHE_TTL:-60}"

mkdir -p "$CACHE_DIR"

force=0
[[ "${1:-}" == "--force" ]] && force=1

if [[ $force -eq 0 && -f "$CACHE_FILE" ]]; then
  age=$(( $(date +%s) - $(stat -f %m "$CACHE_FILE") ))
  if (( age < TTL )); then
    exit 0
  fi
fi

# Single-writer lock so concurrent Alfred queries don't stampede pass-cli.
exec 9>"$LOCK_FILE"
if ! flock -n 9 2>/dev/null; then
  # `flock` is GNU-only; on macOS we fall back to a simple PID file.
  :
fi

if ! command -v pass-cli >/dev/null 2>&1; then
  echo '{"items":[],"error":"pass-cli not found in PATH"}' >"$CACHE_FILE"
  exit 0
fi

if ! pass-cli info >/dev/null 2>&1; then
  echo '{"items":[],"error":"not logged in (run: pass-cli login)"}' >"$CACHE_FILE"
  exit 0
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

vaults_json="$(pass-cli vault list --output json 2>/dev/null || echo '{"vaults":[]}')"

python3 - "$vaults_json" >"$tmp" <<'PY'
import json, subprocess, sys

vaults = json.loads(sys.argv[1]).get("vaults", [])

vault_by_share = {v["share_id"]: v["name"] for v in vaults}

all_items = []
errors = []

for v in vaults:
    name = v["name"]
    share_id = v["share_id"]
    try:
        # --show-secrets gives us usernames/emails/urls in one call. We strip
        # passwords/TOTP below so the cache never holds actual secrets.
        cmd = ["pass-cli", "item", "list", "--share-id", share_id,
               "--output", "json", "--show-secrets"]
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if res.returncode != 0:
            # Fall back to no-secrets listing if --show-secrets is rejected
            # (e.g. agent session).
            res = subprocess.run(
                ["pass-cli", "item", "list", "--share-id", share_id, "--output", "json"],
                capture_output=True, text=True, timeout=30,
            )
        if res.returncode != 0:
            errors.append(f"{name}: {res.stderr.strip()}")
            continue
        data = json.loads(res.stdout)
        for it in data.get("items", []) or []:
            if not isinstance(it, dict) or it.get("state") != "Active":
                continue

            try:
                # When --show-secrets succeeded the item has nested
                # content.content.Login.{email,username,urls,...}. When it
                # didn't, the top-level title/item_type fields are used.
                login_email = ""
                login_username = ""
                login_url = ""
                title = it.get("title") or ""
                item_type = it.get("item_type") or ""

                content = it.get("content")
                if isinstance(content, dict):
                    title = content.get("title") or title
                    inner = content.get("content")
                    if isinstance(inner, dict):
                        L = inner.get("Login")
                        A = inner.get("Alias")
                        if isinstance(L, dict):
                            item_type = item_type or "login"
                            login_email = L.get("email") or ""
                            login_username = L.get("username") or ""
                            urls = L.get("urls") or []
                            if urls:
                                login_url = urls[0] or ""
                        elif isinstance(A, dict):
                            item_type = item_type or "alias"
                            login_email = A.get("alias_email") or A.get("email") or ""

                if not it.get("id") or not it.get("share_id"):
                    continue

                all_items.append({
                    "id": it["id"],
                    "share_id": it["share_id"],
                    "vault_name": vault_by_share.get(it["share_id"], name),
                    "title": title,
                    "item_type": item_type,
                    "modify_time": it.get("modify_time", ""),
                    "login": login_username or login_email,
                    "url": login_url,
                })
            except Exception as e:
                errors.append(f"{name}/{it.get('id','?')[:8]}: {e}")
                continue
    except Exception as e:
        errors.append(f"{name}: {e}")

# Most recently modified first — handy default ordering.
all_items.sort(key=lambda x: x.get("modify_time", ""), reverse=True)

json.dump({"items": all_items, "errors": errors}, sys.stdout)
PY

mv "$tmp" "$CACHE_FILE"
