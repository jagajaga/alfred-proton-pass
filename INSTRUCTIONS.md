# Proton Pass

Search your [Proton Pass](https://proton.me/pass) vaults from Alfred via the official `pass-cli`.

## Setup

Install the Proton Pass CLI and sign in once:

```sh
brew install pass-cli
pass-cli login
```

`pass-cli` keeps an authenticated session, so the workflow can fetch passwords on demand without prompting.

## Usage

Search items across all your vaults via the `pp` keyword. The list matches both the item title and its saved login (username or email).

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
