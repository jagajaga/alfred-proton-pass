<p align="center">
  <img src="icon.png" width="128" height="128" alt="Proton Pass for Alfred" />
</p>

<h1 align="center">alfred-proton-pass</h1>

<p align="center">
  An <a href="https://www.alfredapp.com/">Alfred</a> workflow for
  <a href="https://proton.me/pass">Proton Pass</a>, driving the official
  <a href="https://protonpass.github.io/pass-cli/"><code>pass-cli</code></a>.
</p>

<p align="center">
  <a href="https://github.com/jagajaga/alfred-proton-pass/releases/latest">
    <img alt="latest release" src="https://img.shields.io/github/v/release/jagajaga/alfred-proton-pass?color=6c4ff7&label=download&style=for-the-badge" />
  </a>
  &nbsp;
  <a href="LICENSE">
    <img alt="MIT license" src="https://img.shields.io/badge/license-MIT-6c4ff7?style=for-the-badge" />
  </a>
</p>

---

UX modeled after [`chrisgrieser/alfred-pass`](https://github.com/chrisgrieser/alfred-pass) — same keyword + modifier-key feel, ported to the Proton Pass backend.

## Install

1. Install the Proton Pass CLI and sign in:

   ```sh
   brew install pass-cli
   pass-cli login
   ```

2. Download the latest **Proton Pass.alfredworkflow** from the [Releases](https://github.com/jagajaga/alfred-proton-pass/releases/latest) page and double-click it.

### Staying logged in

The default `pass-cli login` (web) session is short-lived and will eventually
expire — when it does, the workflow shows a *"not logged in"* item instead of
results. For a long-lived session (up to a year), authenticate with a
**Personal Access Token**:

```sh
# create a token once (while logged in); expirations: 1d 1w 1m 3m 6m 1y
pass-cli personal-access-token create --name alfred --expiration 1y
# → prints  pst_<token>::<key>  (shown only once)

# log in with it — establishes a session that lasts as long as the token
pass-cli login --pat 'pst_<token>::<key>'
```

Renew before it lapses with `pass-cli personal-access-token renew`. Treat the
token like a password — don't store it in the workflow; the one-time
`login --pat` is enough, since the session is cached under
`~/.config/pass-cli/.session/`.

## Usage

| Keyword | What it does |
|---|---|
| `pp <query>` | Search items across all your vaults (matches title and login) |
| `ppgen [length]` | Generate a random password (default length 20) and copy |

Inside the `pp` results:

| Key | Action |
|---|---|
| <kbd>↩</kbd> | Copy **password** (clipboard auto-clears after 45 s) |
| <kbd>⌘</kbd><kbd>↩</kbd> | Copy **username/email** |
| <kbd>⌥</kbd><kbd>↩</kbd> | Copy **TOTP code** |
| <kbd>⌃</kbd><kbd>↩</kbd> | Open the item's first **URL** |
| <kbd>⇧</kbd><kbd>↩</kbd> | Show item **details** (password masked) |

### Search

Each item is matched on its **title**, **login** (username/email), and **URL**.

The query is split into space-separated tokens, and **every token must match
at least one field**. That lets you narrow by combining a site with an
account — e.g. `pp goog work` matches the `google.com` entry by title and
your work address by login, and `pp git personal` picks the `github.com`
entry tied to that account. Tokens that land on different fields rank higher,
so the entry matching both your terms floats to the top.

Per token, matches are scored exact → prefix → word-boundary → substring →
subsequence (so `ghb` still finds `github.com`). Title hits outrank login
hits, which outrank URL hits.

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

Actual secrets are **never** written to disk by this workflow — every
copy / TOTP / open-URL action fetches the value live from `pass-cli`.

## Building from source

```sh
zip -r "Proton Pass.alfredworkflow" \
  info.plist icon.png INSTRUCTIONS.md scripts/ \
  -x "*.DS_Store" -x "scripts/__pycache__/*"
```

Drop the resulting `Proton Pass.alfredworkflow` into Alfred.

## License

[MIT](LICENSE).
