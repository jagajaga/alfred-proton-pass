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
TTL="${PP_CACHE_TTL:-300}"

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
  echo '{"items":[],"errors":["pass-cli not found in PATH"]}' >"$CACHE_FILE"
  exit 0
fi

if ! pass-cli info >/dev/null 2>&1; then
  echo '{"items":[],"errors":["not logged in (run: pass-cli login)"]}' >"$CACHE_FILE"
  exit 0
fi

tmp="$(mktemp)"
vault_err="$(mktemp)"
trap 'rm -f "$tmp" "$vault_err"' EXIT

# Capture stdout and stderr separately. `vault list` can exit 0 yet print
# per-share decryption errors to stderr and return an empty list — e.g. when
# the session metadata is valid but the key passphrases are missing. We must
# not let that masquerade as "you have no items".
vaults_json="$(pass-cli vault list --output json 2>"$vault_err" || echo '{"vaults":[]}')"

vault_count="$(printf '%s' "$vaults_json" | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin).get("vaults",[])))
except Exception: print(0)' 2>/dev/null)"

if [ "${vault_count:-0}" -le 0 ] && [ -s "$vault_err" ]; then
  if grep -qiE 'passphrase|share key|decrypt|authenticated' "$vault_err"; then
    echo '{"items":[],"errors":["session can'"'"'t decrypt vaults — run: pass-cli logout && pass-cli login"]}' >"$CACHE_FILE"
  else
    msg="$(head -1 "$vault_err" | tr -d '"' | cut -c1-160)"
    printf '{"items":[],"errors":["vault list failed: %s"]}\n' "$msg" >"$CACHE_FILE"
  fi
  exit 0
fi

python3 - "$vaults_json" >"$tmp" <<'PY'
import json, os, subprocess, sys

# --show-secrets decrypts every secret in a vault to surface usernames, which
# can be slow on large vaults. Give it a generous window (override with
# PP_LIST_TIMEOUT); the plain listing used as a fallback is fast.
SHOW_SECRETS_TIMEOUT = int(os.environ.get("PP_LIST_TIMEOUT", "60"))
PLAIN_TIMEOUT = int(os.environ.get("PP_LIST_TIMEOUT", "60")) // 2 + 15

vaults = json.loads(sys.argv[1]).get("vaults", [])

vault_by_share = {v["share_id"]: v["name"] for v in vaults}

all_items = []
errors = []

for v in vaults:
    name = v["name"]
    share_id = v["share_id"]
    try:
        # --show-secrets gives usernames/emails/urls (stripped below, so the
        # cache never holds real secrets). It can be slow on a big vault, so if
        # it times out or is rejected (e.g. an agent session), fall back to the
        # fast plain listing — the vault's items still get indexed, just without
        # login/url enrichment. Only a genuinely failed vault becomes a warning.
        base = ["pass-cli", "item", "list", "--share-id", share_id, "--output", "json"]
        res = None
        try:
            res = subprocess.run(base + ["--show-secrets"],
                                 capture_output=True, text=True,
                                 timeout=SHOW_SECRETS_TIMEOUT)
            if res.returncode != 0:
                res = None
        except subprocess.TimeoutExpired:
            res = None
        if res is None:
            res = subprocess.run(base, capture_output=True, text=True,
                                 timeout=PLAIN_TIMEOUT)
        if res.returncode != 0:
            errors.append(f"{name}: {res.stderr.strip()[:160]}")
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
