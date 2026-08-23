# Encrypted environment variables

Every benefactor-cc repository keeps its secrets as committed ciphertext under
`env/enc/` and decrypts them, on demand, to gitignored plaintext under `env/dec/`.

```
env/enc/.env.enc            committed  — the default profile
env/enc/.env.ci.enc         committed  — a named profile
env/enc/.recipients         committed  — age public keys that may decrypt
env/dec/.env                IGNORED    — plaintext, mode 0600, never committed
```

One script drives all of it: `scripts/env-crypto.sh`.

```sh
scripts/env-crypto.sh doctor      # what's installed, what's configured, what's unsafe
scripts/env-crypto.sh decrypt     # env/enc/.env.enc -> env/dec/.env
scripts/env-crypto.sh edit        # decrypt to a temp file, open $EDITOR, re-encrypt
scripts/env-crypto.sh encrypt     # env/dec/.env -> env/enc/.env.enc
scripts/env-crypto.sh verify      # every profile decrypts and parses (prints no values)
```

## First-time setup

```sh
brew install age                       # or: apt install age
scripts/env-crypto.sh keygen           # writes ~/.config/benefactor/age.key, prints your public recipient
```

Add the printed `age1…` line to `env/enc/.recipients` in every repo you need to
read, commit that, and ask someone who already has access to run
`scripts/env-crypto.sh rotate` so the existing ciphertext is re-encrypted to the
new recipient list. **Adding yourself to `.recipients` does not grant access on
its own** — the ciphertext has to be rewritten.

## Backends

The ciphertext is self-describing, so `decrypt` always picks the right backend.
`ENV_CRYPTO_BACKEND` only chooses what `encrypt` and `rotate` *write*.

| Backend | Crypto | Diffs | Needs | Use it when |
|---|---|---|---|---|
| `sops` | age (X25519 + ChaCha20-Poly1305) per value | per-variable — `git diff` shows *which* key changed | `sops` + `age` | **Default.** Reviewable diffs matter on a shared repo. |
| `age` | age, whole file, ASCII-armored | opaque — the whole blob changes | `age` | One binary, no per-key metadata, smallest surface. |
| `openssl` | AES-256-CBC, PBKDF2-HMAC-SHA512 ×600 000, integrity canary sealed inside the plaintext | opaque | openssl with `-pbkdf2` | Nothing else is installable, or you want a passphrase rather than a key file. |

Auto-selection when `ENV_CRYPTO_BACKEND` is unset: `sops` → `age` → `openssl`.

`rotate` moves every profile to a new backend in place:

```sh
ENV_CRYPTO_BACKEND=sops scripts/env-crypto.sh rotate
```

Rotation re-encrypts. It does **not** change the secret values — if a key leaked,
rotate the value at the provider as well.

### On the openssl backend's integrity canary

`openssl dgst -macopt hexkey:…` and `openssl kdf -kdfopt pass:…` both require key
material as an argv element, where any local process can read it out of
`/proc/<pid>/cmdline`. `openssl enc -pass env:` does not. So instead of
encrypt-then-MAC over the ciphertext, the digest of the plaintext is sealed
*inside* the encrypted payload:

```
#env-crypto-integrity:v1:sha256=<hex>
<the dotenv body>
```

CBC bit-flipping garbles the target block wholesale, so an attacker cannot
produce a body whose SHA-256 matches an attacker-chosen canary without the key.
Tampering, truncation, and a wrong passphrase all fail closed with a distinct
error, and the plaintext file is removed rather than left half-written.

### On SOPS and comments

SOPS exits 0 and passes a **comment** through verbatim when that comment's GCM
tag fails to verify — it treats it as "possibly an unencrypted comment from an
older SOPS". Value tampering and `sops_mac` tampering are both caught correctly;
comment tampering is not. `env-crypto.sh` closes that gap by rejecting any
decrypted output that still contains a `ENC[AES256_GCM,` envelope.

## Running a command with the secrets loaded

`run` decrypts into the child process's environment and never writes plaintext
to the repository. Prefer it in CI and in cron:

```sh
scripts/env-crypto.sh run -- node send-daily.mjs
scripts/env-crypto.sh run --profile ci -- npm test
```

`decrypt` is for interactive work where a tool insists on reading a `.env` file.
Follow it with `scripts/env-crypto.sh clean` when you're done.

## Guards

These are enforced, not advisory. Each one fails the command rather than warning.

- **Plaintext is never written into a tracked tree.** `decrypt` refuses if
  `env/dec/` is not gitignored, and refuses if anything under `env/dec/` is
  already tracked.
- **`env/dec/.gitignore` ignores everything but itself**, so the rule travels
  with the directory and cannot be lost by an edit to the root `.gitignore`.
- **No double-encryption.** `encrypt` refuses a file that already looks like age,
  SOPS, or env-crypto ciphertext.
- **The plaintext must parse as dotenv** — `KEY=VALUE`, `export KEY=VALUE`,
  comments, blanks — both before encrypting and after decrypting. A garbled
  decryption cannot silently become a "valid" env file.
- **Profile names are `[A-Za-z0-9._-]+`** and cannot contain `..`, so
  `decrypt ../../etc/passwd` is rejected.
- **Modes:** `env/dec` is 0700, decrypted files are 0600, generated age
  identities are 0600 and `keygen` refuses to overwrite an existing one.
- **Temp files** live in a 0700 `mktemp -d` that is overwritten and removed by an
  `EXIT`/`INT`/`TERM` trap.
- **No secret ever reaches stdout, stderr, or a log.** `verify` and `doctor`
  report counts, backends, and file modes only. This is covered by a test.

## CI

`.github/actions/decrypt-env` is a composite action. Give it the age identity
from a repository secret; it installs `age` (and `sops` when needed), decrypts,
and asserts the variables you require are present.

```yaml
- uses: ./.github/actions/decrypt-env
  with:
    age-key: ${{ secrets.ENV_CRYPTO_AGE_KEY }}
    profile: ci
    require: DATABASE_URL,SENDGRID_API_KEY
```

Generate a dedicated CI identity — do not reuse a laptop key:

```sh
ENV_CRYPTO_AGE_KEY_FILE=./ci.key scripts/env-crypto.sh keygen
gh secret set ENV_CRYPTO_AGE_KEY < ./ci.key
age-keygen -y ./ci.key >> env/enc/.recipients
scripts/env-crypto.sh rotate      # re-encrypt so CI can actually read it
shred -u ./ci.key
```

## Pre-commit hook

`.githooks/pre-commit` blocks a commit that stages plaintext under `env/dec/`,
a `.env` outside `env/`, or an age/SOPS private key. Enable it once per clone:

```sh
git config core.hooksPath .githooks
```

## What goes in which profile

| Profile | Contents |
|---|---|
| `default` | Local development. Dry-run defaults, a read-only database role, no live-send confirmations. |
| `ci` | What GitHub Actions needs. Still dry-run: no `LIVE_SEND_CONFIRM`, no `GMAIL_LIVE_CONFIRM`. |
| `live` | Live-send confirmations and the write-capable database role. Restrict `.recipients` for this profile's key to the people who may authorize a send. |

Live-send confirmation tokens are secrets *because* they are the last gate. Keep
them out of `default` and `ci` so an accidental `DRY_RUN=false` still fails closed.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `age identity not found` | No key at `~/.config/benefactor/age.key`. Run `keygen`, or set `ENV_CRYPTO_AGE_KEY_FILE`. |
| `no identity matched any of the recipients` | Your key is not in `env/enc/.recipients`, or it is but nobody has run `rotate` since. |
| `integrity check failed` | The ciphertext changed after it was written — a bad merge, a text-mode checkout, or an edit by hand. Restore from git. |
| `refusing to write plaintext` | `env/dec/` is not ignored. Run `scripts/env-crypto.sh init`. |
| `is not a KEY=VALUE assignment` | A multi-line value. Base64 it into one line (service-account JSON in particular). |
| openssl backend `unusable` in `doctor` | LibreSSL or OpenSSL 1.0 — no `-pbkdf2`. On macOS, `brew install openssl@3`, or just use `age`. |

## Multi-line values

The dotenv format has no multi-line syntax that every consumer agrees on, so
`env-crypto.sh` rejects them. Encode instead:

```sh
GOOGLE_SERVICE_ACCOUNT_JSON_B64=$(base64 -w0 < service-account.json)
```

and decode at the point of use. This also keeps the JSON out of argv and out of
any log that echoes the environment.
