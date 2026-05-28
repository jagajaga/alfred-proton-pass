#!/usr/bin/env python3
"""
Alfred Script Filter: search Proton Pass items.
Reads the cache built by index.sh; refreshes synchronously if missing,
kicks off a background refresh if stale.

Receives the user query on argv (joined with spaces).
Emits Alfred Script Filter JSON on stdout.
"""

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
CACHE_DIR = Path(os.environ.get("alfred_workflow_cache") or HERE.parent / "cache")
CACHE_FILE = CACHE_DIR / "index.json"
TTL = int(os.environ.get("PP_CACHE_TTL", "60"))


def run_indexer(force: bool = False, background: bool = False) -> None:
    args = [str(HERE / "index.sh")]
    if force:
        args.append("--force")
    if background:
        subprocess.Popen(
            args,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    else:
        subprocess.run(args, check=False)


def load_cache() -> dict:
    if not CACHE_FILE.exists():
        run_indexer(force=True)
    else:
        age = time.time() - CACHE_FILE.stat().st_mtime
        if age > TTL:
            run_indexer(background=True)
    try:
        return json.loads(CACHE_FILE.read_text())
    except Exception as e:
        return {"items": [], "errors": [f"cache unreadable: {e}"]}


def score(title: str, query: str) -> int:
    """Higher is better; 0 means no match."""
    if not query:
        return 1
    t = title.lower()
    q = query.lower()
    if t == q:
        return 1000
    if t.startswith(q):
        return 500
    # word-boundary prefix match (e.g. "git" matches "github.com")
    if re.search(r"(^|[\W_])" + re.escape(q), t):
        return 250
    if q in t:
        return 100
    # subsequence fallback so e.g. "ghb" matches "github.com"
    i = 0
    for ch in t:
        if i < len(q) and ch == q[i]:
            i += 1
    if i == len(q):
        return 10
    return 0


TYPE_ICONS = {
    "login": "🔑",
    "alias": "📧",
    "note": "📝",
    "credit-card": "💳",
    "identity": "🪪",
    "ssh-key": "🔐",
    "wifi": "📶",
    "custom": "✳️",
}


def emit_login_required(message: str) -> None:
    print(json.dumps({
        "items": [{
            "title": "Proton Pass: not logged in",
            "subtitle": f"{message} — press Enter to run `pass-cli login` in Terminal",
            "arg": "login|||",
            "valid": True,
            "icon": {"path": "icon.png"},
        }]
    }))


def main() -> int:
    query = " ".join(sys.argv[1:]).strip()
    data = load_cache()

    errors = data.get("errors") or []
    items_in = data.get("items") or []

    if not items_in and errors:
        emit_login_required(errors[0])
        return 0

    matches = []
    for it in items_in:
        s_title = score(it.get("title", ""), query)
        # Match login too, but at a lower weight so title hits still win.
        s_login = score(it.get("login", ""), query) // 2 if it.get("login") else 0
        s = max(s_title, s_login)
        if s == 0:
            continue
        matches.append((s, it))

    # With a query: sort by score desc, then title. Empty query: keep cache
    # order (most-recently-modified first).
    if query:
        matches.sort(key=lambda x: (-x[0], x[1].get("title", "").lower()))
    matches = matches[:50]

    out_items = []
    for _, it in matches:
        title = it.get("title", "(untitled)")
        it_type = it.get("item_type", "")
        vault = it.get("vault_name", "")
        share_id = it.get("share_id", "")
        item_id = it.get("id", "")
        login = it.get("login", "")

        icon = TYPE_ICONS.get(it_type, "•")
        # Login (username/email) first so it's easy to scan; vault second.
        parts = [icon]
        if login:
            parts.append(login)
        parts.append(vault)
        subtitle = " · ".join(parts)

        base_arg = f"password|{share_id}|{item_id}|{title}"

        out_items.append({
            "uid": item_id,
            "title": title,
            "subtitle": f"{subtitle}  ⏎ copy password",
            "arg": base_arg,
            "valid": True,
            "match": title.replace(".", " ").replace("-", " ").replace("_", " "),
            "mods": {
                "cmd": {
                    "subtitle": f"{subtitle}  ⌘⏎ copy username/email",
                    "arg": f"username|{share_id}|{item_id}|{title}",
                    "valid": True,
                },
                "alt": {
                    "subtitle": f"{subtitle}  ⌥⏎ copy TOTP code",
                    "arg": f"totp|{share_id}|{item_id}|{title}",
                    "valid": True,
                },
                "shift": {
                    "subtitle": f"{subtitle}  ⇧⏎ show full details",
                    "arg": f"details|{share_id}|{item_id}|{title}",
                    "valid": True,
                },
                "ctrl": {
                    "subtitle": f"{subtitle}  ⌃⏎ open first URL",
                    "arg": f"url|{share_id}|{item_id}|{title}",
                    "valid": True,
                },
            },
        })

    if not out_items:
        out_items.append({
            "title": "No matches",
            "subtitle": f'No Proton Pass items match "{query}"' if query else "No items in your vaults",
            "valid": False,
            "icon": {"path": "icon.png"},
        })

    payload = {"items": out_items}
    # Tell Alfred to re-query while the cache is being refreshed in the background.
    if errors:
        payload["items"].insert(0, {
            "title": "Warning while indexing",
            "subtitle": "; ".join(errors)[:200],
            "valid": False,
            "icon": {"path": "icon.png"},
        })

    print(json.dumps(payload))
    return 0


if __name__ == "__main__":
    sys.exit(main())
