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


def score_token(text: str, token: str) -> int:
    """Score a single token against a single field. Higher = better; 0 = miss."""
    if not token:
        return 1
    if not text:
        return 0
    t = text.lower()
    q = token.lower()
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


# Per-field weights, applied to each token's score against that field.
# Title wins ties, login is half-weight, URL is third (URL usually contains
# the domain that's already in the title, so it's mostly a fallback).
FIELD_WEIGHTS = (("title", 1.0), ("login", 0.5), ("url", 0.33))


def item_score(item: dict, tokens: list[str]) -> int:
    """Score an item against an already-tokenized query.

    All tokens must match SOME field for the item to qualify; the per-token
    score is the best (weighted) score across fields, and the item's total
    is the sum across tokens. A small bonus is added when different tokens
    match different fields — that's the case where a multi-word query like
    `goog bloop` really pays off.
    """
    if not tokens:
        return 1

    fields = {f: (item.get(f) or "") for f, _ in FIELD_WEIGHTS}
    weights = dict(FIELD_WEIGHTS)

    total = 0
    matched_fields: set[str] = set()
    for tok in tokens:
        best = 0
        best_field = None
        for f, _ in FIELD_WEIGHTS:
            s = int(score_token(fields[f], tok) * weights[f])
            if s > best:
                best = s
                best_field = f
        if best == 0:
            return 0  # token didn't match any field → item is out
        total += best
        if best_field:
            matched_fields.add(best_field)

    # Bonus when tokens spread across different fields (rewards `goog bloop`
    # hitting title + login over a single field carrying everything).
    if len(matched_fields) > 1:
        total += 50 * (len(matched_fields) - 1)
    return total


def tokenize(q: str) -> list[str]:
    return [t for t in q.lower().split() if t]


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

    # Accept both "errors" (list) and a legacy singular "error" (string) so a
    # stale cache from an older build still surfaces the real reason.
    errors = data.get("errors") or []
    if not errors and data.get("error"):
        errors = [data["error"]]
    items_in = data.get("items") or []

    if not items_in and errors:
        emit_login_required(errors[0])
        return 0

    tokens = tokenize(query)
    matches = []
    for it in items_in:
        s = item_score(it, tokens)
        if s == 0:
            continue
        matches.append((s, it))

    # With a query: sort by score desc, then title. Empty query: keep cache
    # order (most-recently-modified first).
    if tokens:
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
