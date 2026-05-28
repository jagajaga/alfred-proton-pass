#!/bin/bash
# Generate a password via pass-cli and copy it to the clipboard.
# Optional first argument: length (default 20).

set -euo pipefail

PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

length="${1:-20}"
# Allow plain numeric input; ignore anything weird.
if ! [[ "$length" =~ ^[0-9]+$ ]]; then
  length=20
fi

CLIP_CLEAR_SECONDS="${PP_CLIP_CLEAR:-45}"

if value="$(pass-cli password generate random --length "$length" 2>&1)"; then
  printf '%s' "$value" | /usr/bin/pbcopy
  /usr/bin/osascript -e "display notification \"Generated ${length}-char password copied (clears in ${CLIP_CLEAR_SECONDS}s)\" with title \"Proton Pass\"" 2>/dev/null || true
  if (( CLIP_CLEAR_SECONDS > 0 )); then
    (
      sleep "$CLIP_CLEAR_SECONDS"
      current="$(/usr/bin/pbpaste 2>/dev/null || true)"
      if [[ "$current" == "$value" ]]; then
        printf '' | /usr/bin/pbcopy
      fi
    ) >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi
else
  /usr/bin/osascript -e "display notification \"Failed: $value\" with title \"Proton Pass\"" 2>/dev/null || true
  exit 1
fi
