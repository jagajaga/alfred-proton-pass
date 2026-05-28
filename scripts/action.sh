#!/bin/bash
# Dispatch an Alfred action against a Proton Pass item.
# Receives one argument: ACTION|SHARE_ID|ITEM_ID|TITLE
#
# ACTION ∈ {password, username, totp, url, details, login}

set -euo pipefail

PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

CLIP_CLEAR_SECONDS="${PP_CLIP_CLEAR:-45}"

arg="${1:-}"
IFS='|' read -r action share_id item_id title <<<"$arg"

notify() {
  local title="$1" message="$2"
  /usr/bin/osascript -e "display notification \"${message//\"/\\\"}\" with title \"${title//\"/\\\"}\"" 2>/dev/null || true
}

copy_transient() {
  # Copy $1 to clipboard and schedule a clear after $CLIP_CLEAR_SECONDS.
  printf '%s' "$1" | /usr/bin/pbcopy
  if (( CLIP_CLEAR_SECONDS > 0 )); then
    (
      sleep "$CLIP_CLEAR_SECONDS"
      # Only clear if the clipboard still holds this value, so we don't
      # nuke whatever the user copied since.
      current="$(/usr/bin/pbpaste 2>/dev/null || true)"
      if [[ "$current" == "$1" ]]; then
        printf '' | /usr/bin/pbcopy
      fi
    ) >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi
}

case "$action" in
  login)
    /usr/bin/osascript <<'OSA' >/dev/null 2>&1
tell application "Terminal"
  activate
  do script "pass-cli login"
end tell
OSA
    exit 0
    ;;

  password)
    if value="$(pass-cli item view --share-id "$share_id" --item-id "$item_id" --field password 2>&1)"; then
      copy_transient "$value"
      notify "Proton Pass" "Password for $title copied (clears in ${CLIP_CLEAR_SECONDS}s)"
    else
      notify "Proton Pass" "Could not read password: $value"
    fi
    ;;

  username)
    # Try the `username` field, fall back to `email`.
    if value="$(pass-cli item view --share-id "$share_id" --item-id "$item_id" --field username 2>/dev/null)" && [[ -n "$value" ]]; then
      copy_transient "$value"
      notify "Proton Pass" "Username for $title copied"
    elif value="$(pass-cli item view --share-id "$share_id" --item-id "$item_id" --field email 2>/dev/null)" && [[ -n "$value" ]]; then
      copy_transient "$value"
      notify "Proton Pass" "Email for $title copied"
    else
      notify "Proton Pass" "No username or email on $title"
    fi
    ;;

  totp)
    if value="$(pass-cli item totp --share-id "$share_id" --item-id "$item_id" --output json 2>&1)"; then
      code="$(printf '%s' "$value" | /usr/bin/python3 -c 'import json,sys;d=json.load(sys.stdin);print((d.get("totp") or d.get("code") or list(d.values())[0]) if isinstance(d, dict) else d)')" || code=""
      if [[ -n "$code" ]]; then
        copy_transient "$code"
        notify "Proton Pass" "TOTP for $title copied"
      else
        notify "Proton Pass" "No TOTP configured on $title"
      fi
    else
      notify "Proton Pass" "TOTP failed: $value"
    fi
    ;;

  url)
    json="$(pass-cli item view --share-id "$share_id" --item-id "$item_id" --output json 2>&1)" || {
      notify "Proton Pass" "Could not read item"
      exit 0
    }
    url="$(printf '%s' "$json" | /usr/bin/python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    urls = d.get("item", {}).get("content", {}).get("content", {}).get("Login", {}).get("urls", [])
    print(urls[0] if urls else "")
except Exception:
    print("")
')"
    if [[ -n "$url" ]]; then
      /usr/bin/open "$url"
    else
      notify "Proton Pass" "No URL on $title"
    fi
    ;;

  details)
    json="$(pass-cli item view --share-id "$share_id" --item-id "$item_id" --output json 2>&1)" || {
      notify "Proton Pass" "Could not read item"
      exit 0
    }
    # Render a sanitized summary (no secrets) into a dialog.
    summary="$(printf '%s' "$json" | /usr/bin/python3 - "$title" <<'PY'
import json, sys
title = sys.argv[1]
try:
    d = json.load(sys.stdin)
    item = d.get("item", {})
    content = item.get("content", {})
    inner = content.get("content", {})
    note = content.get("note", "")
    lines = [f"Title: {title}"]
    if "Login" in inner:
        L = inner["Login"]
        if L.get("email"):    lines.append(f"Email: {L['email']}")
        if L.get("username"): lines.append(f"Username: {L['username']}")
        if L.get("password"): lines.append(f"Password: {'•' * 12}")
        if L.get("totp_uri"): lines.append("TOTP: configured")
        for u in L.get("urls", []): lines.append(f"URL: {u}")
    elif "Note" in inner:
        lines.append("Type: note")
    elif "CreditCard" in inner:
        C = inner["CreditCard"]
        if C.get("cardholder_name"): lines.append(f"Holder: {C['cardholder_name']}")
        if C.get("number"): lines.append(f"Number: •••• {C['number'][-4:]}")
    if note:
        lines.append("")
        lines.append(f"Note: {note}")
    print("\n".join(lines))
except Exception as e:
    print(f"(could not parse: {e})")
PY
)"
    /usr/bin/osascript <<OSA >/dev/null 2>&1 || true
display dialog "${summary//\"/\\\"}" with title "Proton Pass — ${title//\"/\\\"}" buttons {"OK"} default button "OK"
OSA
    ;;

  *)
    notify "Proton Pass" "Unknown action: $action"
    exit 1
    ;;
esac
