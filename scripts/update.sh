#!/bin/bash
# Self-updater. Checks the GitHub "latest release" for a newer version and, if
# found, downloads the .alfredworkflow and opens it so Alfred shows its import
# dialog (the user confirms the install — nothing happens silently).
#
# Spawned in the background by filter.py, throttled to once a day. Reads the
# installed version from $alfred_workflow_version (set by Alfred).

set -uo pipefail
PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

REPO="${PP_REPO:-jagajaga/alfred-proton-pass}"
current="${alfred_workflow_version:-0.0.0}"

api="https://api.github.com/repos/$REPO/releases/latest"
json="$(curl -fsSL --max-time 20 -H 'Accept: application/vnd.github+json' "$api" 2>/dev/null)" || exit 0
[ -n "$json" ] || exit 0

latest_tag="$(printf '%s' "$json" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin).get("tag_name",""))' 2>/dev/null)"
latest="${latest_tag#v}"
[ -n "$latest" ] || exit 0

# Only proceed if latest is strictly newer than current (sort -V handles semver).
newest="$(printf '%s\n%s\n' "$current" "$latest" | sort -V | tail -1)"
if [ "$latest" = "$current" ] || [ "$newest" != "$latest" ]; then
  exit 0
fi

# Find the .alfredworkflow asset URL.
url="$(printf '%s' "$json" | /usr/bin/python3 -c '
import json, sys
d = json.load(sys.stdin)
for a in d.get("assets", []):
    if a.get("name", "").endswith(".alfredworkflow"):
        print(a.get("browser_download_url", "")); break
' 2>/dev/null)"
[ -n "$url" ] || exit 0

dir="$(mktemp -d)"
file="$dir/Proton Pass ${latest}.alfredworkflow"
if ! curl -fsSL --max-time 60 -o "$file" "$url" 2>/dev/null; then
  rm -rf "$dir"
  exit 0
fi

/usr/bin/osascript -e "display notification \"Installing update ${latest} (was ${current})…\" with title \"Proton Pass\"" 2>/dev/null || true
# open → Alfred's import/update dialog; the user confirms.
/usr/bin/open "$file"
