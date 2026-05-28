# alfred-proton-pass

An [Alfred](https://www.alfredapp.com/) workflow for [Proton Pass](https://proton.me/pass)
that drives the official [`pass-cli`](https://protonpass.github.io/pass-cli/) — the same
way [`chrisgrieser/alfred-pass`](https://github.com/chrisgrieser/alfred-pass) drives the
classic `pass` command.

## Install

1. Install and log in to the Proton Pass CLI:

   ```sh
   brew install pass-cli
   pass-cli login
   ```

2. Download [`Proton Pass.alfredworkflow`](Proton%20Pass.alfredworkflow) and double-click it.

## Usage

| Keyword | What it does |
|---|---|
| `pp <query>` | Search items across all your vaults (matches title and login) |
| `ppgen [length]` | Generate a random password (default length 20) and copy |

Inside the `pp` results:

| Key | Action |
|---|---|
| ⏎ | Copy **password** (clipboard auto-clears after 45 s) |
| ⌘⏎ | Copy **username/email** |
| ⌥⏎ | Copy **TOTP code** |
| ⌃⏎ | Open the item's first **URL** |
| ⇧⏎ | Show item **details** (password masked) |

## Configuration

Workflow variables (Alfred → Workflows → Proton Pass → `[𝗑]`):

- `PP_CACHE_TTL` — seconds before the item index is re-fetched (default `60`).
  Refresh runs in the background; only the very first query after install blocks on it.
- `PP_CLIP_CLEAR` — seconds before the workflow clears the clipboard
  (default `45`; `0` disables). Clearing only happens if the clipboard still
  holds the value the workflow put there.

## How it works

1. `scripts/index.sh` calls `pass-cli vault list` and then
   `pass-cli item list --share-id … --output json --show-secrets` for each
   vault, **strips passwords / TOTP URIs / passkeys**, and merges the results
   into `cache/index.json`. The cache contains only non-secret metadata
   (titles, usernames/emails, URLs).
2. `scripts/filter.py` reads the cache, scores titles + logins against your
   query, and emits the Alfred Script Filter JSON with modifier-key variants.
3. `scripts/action.sh` is the dispatcher. It decodes the
   `ACTION|SHARE_ID|ITEM_ID|TITLE` payload from the chosen item and calls
   `pass-cli item view --field …` or `pass-cli item totp` to fetch exactly the
   value being copied.

Actual secrets are **never** written to disk by this workflow — every copy/TOTP
action fetches the value live from `pass-cli`.

## Building from source

```sh
cd alfred-proton-pass
zip -r "../Proton Pass.alfredworkflow" . -x "cache/*" -x "*.DS_Store" -x "*.lock"
```

## Credits

UX modeled after [`chrisgrieser/alfred-pass`](https://github.com/chrisgrieser/alfred-pass).
Code is independent — the `pass-cli` backend is unrelated to GPG-based `pass`.

## License

MIT
