#!/bin/bash
# Build a JSON cache of all items across all vaults.
# Output: ${alfred_workflow_cache:-./cache}/index.json
#
# Usage:
#   index.sh           # refresh if cache is missing or older than TTL
#   index.sh --force   # refresh unconditionally

set -euo pipefail

# Alfred's PATH is minimal, so add the Homebrew locations. Appended rather than
# prepended so an earlier PATH entry (e.g. the test double in tests/bin) wins.
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

CACHE_DIR="${alfred_workflow_cache:-$(dirname "$0")/../cache}"
CACHE_FILE="$CACHE_DIR/index.json"
TTL="${PP_CACHE_TTL:-300}"
# Seconds between retries when `pass-cli info` fails (see below).
RETRY_DELAY="${PP_RETRY_DELAY:-1}"

mkdir -p "$CACHE_DIR"

# File mtime in epoch seconds. GNU/Linux `stat -c` is tried first because BSD
# stat rejects it, whereas GNU stat accepts `-f` with a different meaning.
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

force=0
[[ "${1:-}" == "--force" ]] && force=1

if [[ $force -eq 0 && -f "$CACHE_FILE" ]]; then
  age=$(( $(date +%s) - $(mtime "$CACHE_FILE") ))
  if (( age < TTL )); then
    exit 0
  fi
fi

# Single-writer lock so concurrent Alfred queries don't stampede pass-cli.
# `flock` doesn't ship with macOS, so the lock is an atomic `mkdir`. Running
# several pass-cli processes at once can race on the session-token refresh and
# make `info` fail spuriously (#3), so a second indexer waits for the first and
# then reuses whatever it wrote instead of indexing again.
LOCK_DIR="$CACHE_DIR/index.lockdir"
LOCK_STALE_AFTER=120   # seconds; a lock older than this was left by a killed run
LOCK_WAIT_MAX=30       # polls of 0.5s before giving up on a slow holder
lock_held=0
cleanup() {
  rm -f "${tmp:-}" "${vault_err:-}"
  (( lock_held )) && rmdir "$LOCK_DIR" 2>/dev/null
  return 0
}
trap cleanup EXIT

waited=0
spins=0
until mkdir "$LOCK_DIR" 2>/dev/null; do
  spins=$((spins + 1))
  (( spins > 200 )) && exit 0   # never busy-loop, whatever stat/mkdir are doing
  lock_mtime="$(mtime "$LOCK_DIR")"
  if [[ -z "$lock_mtime" ]]; then
    continue   # holder released it between our mkdir and stat; retry at once
  fi
  if (( $(date +%s) - lock_mtime > LOCK_STALE_AFTER )); then
    rmdir "$LOCK_DIR" 2>/dev/null
    continue
  fi
  if (( waited >= LOCK_WAIT_MAX )); then
    exit 0   # holder is still going; the caller reads whatever cache exists
  fi
  sleep 0.5
  waited=$((waited + 1))
done
lock_held=1
if (( waited > 0 )); then
  exit 0   # another indexer just finished and wrote the cache; reuse it
fi

if ! command -v pass-cli >/dev/null 2>&1; then
  echo '{"items":[],"errors":["pass-cli not found in PATH"]}' >"$CACHE_FILE"
  exit 0
fi

# `info` can fail for a moment while pass-cli refreshes its session token
# (#2, #3). Retry a few times before declaring "not logged in", otherwise the
# transient error is cached and shown until the cache expires.
logged_in=0
for attempt in 1 2 3; do
  if pass-cli info >/dev/null 2>&1; then
    logged_in=1
    break
  fi
  (( attempt < 3 )) && sleep "$RETRY_DELAY"
done
if (( ! logged_in )); then
  echo '{"items":[],"errors":["not logged in (run: pass-cli login)"]}' >"$CACHE_FILE"
  exit 0
fi

tmp="$(mktemp)"
vault_err="$(mktemp)"

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
