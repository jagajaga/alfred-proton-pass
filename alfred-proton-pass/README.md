# Proton Pass for Alfred

Alfred workflow that drives the official [Proton Pass CLI](https://protonpass.github.io/pass-cli/)
the same way `chrisgrieser/alfred-pass` drives the classic `pass` command.

## Requirements

- macOS + [Alfred](https://www.alfredapp.com/) with the Powerpack
- [`pass-cli`](https://protonpass.github.io/pass-cli/) on your `PATH`
- You must be logged in once: `pass-cli login`
- Python 3 (ships with macOS)

```sh
brew install pass-cli
pass-cli login
```

## Install

Double-click `Proton Pass.alfredworkflow`. Alfred imports it.

Or, for development: in Alfred → Workflows → drag this folder into the sidebar
(or `cp -R alfred-proton-pass ~/Library/Application\ Support/Alfred/Alfred.alfredpreferences/workflows/`).

## Usage

| Keyword | What it does |
|---|---|
| `pp <query>` | Search items across all your vaults |
| `ppgen [length]` | Generate a random password (default length 20) and copy it |

Inside the `pp` results:

| Key | Action |
|---|---|
| ⏎ | Copy **password** to clipboard (auto-clears in 45 s) |
| ⌘⏎ | Copy **username/email** |
| ⌥⏎ | Copy **TOTP code** |
| ⌃⏎ | Open the item's first **URL** in your default browser |
| ⇧⏎ | Show item **details** (no secrets shown — password is masked) |

If you're not logged in, the first result will tell you, and pressing Enter
opens Terminal to run `pass-cli login`.

## Workflow variables

Set these in Alfred → Workflows → Proton Pass → `[𝗑]` (variables):

- `PP_CACHE_TTL` — seconds before the item index is re-fetched (default `60`).
  Re-indexing happens in the background; only the very first query after install
  blocks on it.
- `PP_CLIP_CLEAR` — seconds before the workflow clears the clipboard
  (default `45`; set to `0` to disable). Clearing only happens if the clipboard
  still holds the secret we put there.

## How it works

1. `scripts/index.sh` calls `pass-cli vault list` and then
   `pass-cli item list --share-id … --output json` for each vault, merging the
   results into `cache/index.json`.
2. `scripts/filter.py` reads the cache, scores titles against your query, and
   emits the Alfred Script Filter JSON with modifier-key variants.
3. `scripts/action.sh` is the dispatcher. It decodes the
   `ACTION|SHARE_ID|ITEM_ID|TITLE` payload Alfred forwards from the chosen item
   and calls `pass-cli item view --field …` or `pass-cli item totp` to fetch
   exactly the value being copied.

Secrets are never written to the cache. Each copy / TOTP / URL action fetches
the value live from `pass-cli`.

## Known limitations

- Item creation (`pp new`) isn't included — `pass-cli item create` has many
  flags and is more comfortable to use directly in the terminal.
- Multi-line note bodies aren't shown in the details dialog (note headers only).
- If you have many large vaults the first index build can take several seconds.
  Subsequent queries use the cached index until `PP_CACHE_TTL` elapses.

## Credits

UX modeled after [chrisgrieser/alfred-pass](https://github.com/chrisgrieser/alfred-pass).
