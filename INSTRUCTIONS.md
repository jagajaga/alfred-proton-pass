# Proton Pass

Search your [Proton Pass](https://proton.me/pass) vaults from Alfred via the official `pass-cli`.

## Setup

Install the Proton Pass CLI and sign in once:

```sh
brew install pass-cli
pass-cli login
```

`pass-cli` keeps an authenticated session, so the workflow can fetch passwords on demand without prompting.

The default web session is short-lived. For a long-lived session (up to a year), log in with a Personal Access Token instead. Note that a fresh token has **no vault access** until you grant it, so the create, grant, and login steps all matter:

```sh
# 1. create the token and capture it (lifetime: 1d 1w 1m 3m 6m 1y)
TOKEN=$(pass-cli personal-access-token create --name alfred --expiration 1y --output json \
  | python3 -c 'import json,sys
def find(o):
    if isinstance(o,str): return o if o.startswith("pst_") else None
    if isinstance(o,(list,dict)):
        for v in (o.values() if isinstance(o,dict) else o):
            r=find(v)
            if r: return r
print(find(json.load(sys.stdin)) or "")')

# 2. grant it read access to every vault
for sid in $(pass-cli vault list --output json \
      | python3 -c 'import json,sys;[print(v["share_id"]) for v in json.load(sys.stdin)["vaults"]]'); do
  pass-cli personal-access-token access grant --personal-access-token-name alfred --share-id "$sid" --role viewer
done

# 3. log in with the token, then wipe the variable
pass-cli logout
pass-cli login --pat "$TOKEN"; unset TOKEN
```

The full version (with verification and notes) is in the project README. If the session ever lapses, the workflow shows a "not logged in" item — press Enter on it to re-authenticate.

## Usage

Search items across all your vaults via the `pp` keyword. Each item is matched on its title, login (username or email), and URL.

The query is split into space-separated tokens, and every token must match at least one field. So `pp goog work` finds the `google.com` item matched by both its title and your work login, and `pp git personal` narrows a `github.com` entry by account. Single-word queries work exactly as before.

* <kbd>↩</kbd> Copy the password to the clipboard. The clipboard is automatically cleared after 45 seconds.
* <kbd>⌘</kbd><kbd>↩</kbd> Copy the username/email.
* <kbd>⌥</kbd><kbd>↩</kbd> Copy the TOTP code.
* <kbd>⌃</kbd><kbd>↩</kbd> Open the item's first URL in your default browser.
* <kbd>⇧</kbd><kbd>↩</kbd> Show item details (the password is masked).

Generate a fresh random password via the `ppgen` keyword. Pass an optional length (default `20`).

## Configuration

Adjust the following in the Workflow's Configuration:

* `PP_CACHE_TTL` — seconds before the item index is re-fetched in the background. Default `60`.
* `PP_CLIP_CLEAR` — seconds before the workflow clears the clipboard. Set to `0` to disable. Default `45`. The clipboard is only cleared if it still holds the value the workflow put there.

## Notes

Item titles, usernames/emails, and URLs are cached locally for fast searching. Actual secrets — passwords, TOTP codes, passkeys — are never written to disk; they are fetched live from `pass-cli` at copy time.
