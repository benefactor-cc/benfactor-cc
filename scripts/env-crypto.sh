#!/usr/bin/env bash
# env-crypto — encrypted dotenv management for benefactor-cc repositories.
#
# canonical-source: benefactor-cc/benefactor-lib :: scripts/env-crypto/env-crypto.sh
# version: 1.0.0
#
# Layout (per repository):
#   env/enc/.env.enc            committed ciphertext, default profile
#   env/enc/.env.<profile>.enc  committed ciphertext, named profile
#   env/enc/.recipients         committed age recipient list (age/sops backends)
#   env/dec/.env                DECRYPTED PLAINTEXT — gitignored, mode 0600
#
# Backends (ciphertext is self-describing; `decrypt` auto-detects):
#   sops     SOPS + age. Per-key encryption, readable diffs, multi-recipient.
#   age      age, ASCII-armored. Whole-file, multi-recipient, one binary.
#   openssl  AES-256-CBC + PBKDF2-HMAC-SHA512(600k), with a keyed integrity
#            canary sealed INSIDE the plaintext. Passphrase-based. Requires an
#            `openssl enc` that supports -pbkdf2; the passphrase is passed via
#            the environment, never on the command line.
#
# Key material, by backend:
#   sops/age  ENV_CRYPTO_AGE_KEY       raw age identity (CI: from a secret)
#             ENV_CRYPTO_AGE_KEY_FILE  path to an age identity file
#                                      default ~/.config/benefactor/age.key
#             ENV_CRYPTO_AGE_RECIPIENTS  space/comma/newline separated age1...
#                                        (falls back to env/enc/.recipients)
#   openssl   ENV_CRYPTO_PASSPHRASE       passphrase (CI: from a secret)
#             ENV_CRYPTO_PASSPHRASE_FILE  path to a file holding it
#
# This script never prints a secret value, a passphrase, or a private key.

set -o errexit
set -o nounset
set -o pipefail

readonly ENV_CRYPTO_VERSION='1.0.0'
readonly OPENSSL_MAGIC='#benefactor-env-crypto:v1:openssl-aes256-cbc-pbkdf2'
readonly INTEGRITY_PREFIX='#env-crypto-integrity:v1:sha256='
readonly AGE_MAGIC='-----BEGIN AGE ENCRYPTED FILE-----'
readonly PBKDF2_ITER=600000

# --------------------------------------------------------------------------
# output helpers — stderr only, never carries secret material
# --------------------------------------------------------------------------

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  readonly C_RED=$'\033[31m' C_YLW=$'\033[33m' C_GRN=$'\033[32m' C_DIM=$'\033[2m' C_OFF=$'\033[0m'
else
  readonly C_RED='' C_YLW='' C_GRN='' C_DIM='' C_OFF=''
fi

log()  { printf '%s\n' "$*" >&2; }
info() { printf '%s\n' "$*" >&2; }
ok()   { printf '%s%s%s\n' "$C_GRN" "$*" "$C_OFF" >&2; }
warn() { printf '%swarning:%s %s\n' "$C_YLW" "$C_OFF" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

# --------------------------------------------------------------------------
# repository layout
# --------------------------------------------------------------------------

repo_root() {
  if root=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n "$root" ]; then
    printf '%s' "$root"
    return 0
  fi
  # Not a git checkout: fall back to the directory containing scripts/env-crypto.sh
  local here
  here=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
  printf '%s' "$here"
}

ROOT=$(repo_root)
readonly ROOT
readonly ENC_DIR="$ROOT/env/enc"
readonly DEC_DIR="$ROOT/env/dec"

profile_enc_path() {
  local profile=$1
  if [ "$profile" = 'default' ]; then printf '%s/.env.enc' "$ENC_DIR"
  else printf '%s/.env.%s.enc' "$ENC_DIR" "$profile"; fi
}

profile_dec_path() {
  local profile=$1
  if [ "$profile" = 'default' ]; then printf '%s/.env' "$DEC_DIR"
  else printf '%s/.env.%s' "$DEC_DIR" "$profile"; fi
}

validate_profile() {
  case $1 in
    ''|*[!a-zA-Z0-9._-]*) die "invalid profile name: profiles match [A-Za-z0-9._-]+" ;;
    .*|*..*)              die "invalid profile name: must not start with '.' or contain '..'" ;;
  esac
}

# --------------------------------------------------------------------------
# temp-file hygiene
# --------------------------------------------------------------------------

TMPDIR_SELF=''
cleanup() {
  local status=$?
  if [ -n "$TMPDIR_SELF" ] && [ -d "$TMPDIR_SELF" ]; then
    find "$TMPDIR_SELF" -type f -exec dd if=/dev/zero of={} bs=1 count=64 conv=notrunc status=none \; 2>/dev/null || true
    rm -rf -- "$TMPDIR_SELF"
  fi
  return $status
}
trap cleanup EXIT INT TERM

scratch_dir() {
  if [ -z "$TMPDIR_SELF" ]; then
    TMPDIR_SELF=$(mktemp -d "${TMPDIR:-/tmp}/env-crypto.XXXXXXXX")
    chmod 700 "$TMPDIR_SELF"
  fi
  printf '%s' "$TMPDIR_SELF"
}

# --------------------------------------------------------------------------
# backend detection
# --------------------------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

openssl_is_usable() {
  have openssl || return 1
  # -pbkdf2 and -pass env: are the two load-bearing features. Old OpenSSL 1.0
  # and some LibreSSL builds lack -pbkdf2 and would silently fall back to the
  # single-round EVP_BytesToKey KDF, so probe rather than parse the version.
  ENV_CRYPTO_PROBE_PASS='probe' \
  printf 'x' | ENV_CRYPTO_PROBE_PASS='probe' openssl enc -aes-256-cbc -pbkdf2 -iter 2 \
    -md sha512 -pass env:ENV_CRYPTO_PROBE_PASS -a >/dev/null 2>&1
}

detect_ciphertext_backend() {
  local path=$1 first
  [ -f "$path" ] || die "no ciphertext at ${path#"$ROOT/"}"
  first=$(head -n 1 -- "$path" 2>/dev/null || true)
  case $first in
    "$OPENSSL_MAGIC"*) printf 'openssl'; return 0 ;;
    "$AGE_MAGIC"*)     printf 'age';     return 0 ;;
  esac
  # SOPS: dotenv output carries `sops_version=`; yaml/json outputs carry a
  # `sops:` / `"sops":` metadata block. Accept all three shapes.
  if grep -qE '^(sops_version=|sops:|[[:space:]]*"sops"[[:space:]]*:)' -- "$path" 2>/dev/null; then
    printf 'sops'; return 0
  fi
  die "cannot identify the encryption backend of ${path#"$ROOT/"} (not sops, age, or env-crypto/openssl)"
}

resolve_backend_for_write() {
  local requested=${ENV_CRYPTO_BACKEND:-}
  if [ -n "$requested" ]; then
    case $requested in
      sops|age|openssl) printf '%s' "$requested"; return 0 ;;
      *) die "ENV_CRYPTO_BACKEND must be one of: sops, age, openssl (got: $requested)" ;;
    esac
  fi
  if have sops && have age; then printf 'sops'; return 0; fi
  if have age; then printf 'age'; return 0; fi
  if openssl_is_usable; then printf 'openssl'; return 0; fi
  die "no usable backend found. Install \`age\` (recommended) or \`sops\`+\`age\`, or provide OpenSSL 3.x. Run: $0 doctor"
}

# --------------------------------------------------------------------------
# key material
# --------------------------------------------------------------------------

age_identity_file() {
  # Prefer inline key material (CI), then an explicit path, then the default.
  if [ -n "${ENV_CRYPTO_AGE_KEY:-}" ]; then
    local dir path
    dir=$(scratch_dir); path="$dir/age.key"
    ( umask 077; printf '%s\n' "$ENV_CRYPTO_AGE_KEY" > "$path" )
    printf '%s' "$path"; return 0
  fi
  local candidate=${ENV_CRYPTO_AGE_KEY_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/benefactor/age.key}
  [ -f "$candidate" ] || die "age identity not found at ${candidate}. Set ENV_CRYPTO_AGE_KEY / ENV_CRYPTO_AGE_KEY_FILE, or run: $0 keygen"
  printf '%s' "$candidate"
}

age_recipients() {
  local raw=''
  if [ -n "${ENV_CRYPTO_AGE_RECIPIENTS:-}" ]; then
    raw=$ENV_CRYPTO_AGE_RECIPIENTS
  elif [ -f "$ENC_DIR/.recipients" ]; then
    raw=$(grep -vE '^[[:space:]]*(#|$)' -- "$ENC_DIR/.recipients" || true)
  fi
  raw=$(printf '%s' "$raw" | tr ',' '\n' | tr -s '[:space:]' '\n' | grep -E '^(age1|ssh-)' || true)
  [ -n "$raw" ] || die "no age recipients configured. Add them to env/enc/.recipients (one per line) or set ENV_CRYPTO_AGE_RECIPIENTS."
  printf '%s' "$raw"
}

openssl_passphrase() {
  if [ -n "${ENV_CRYPTO_PASSPHRASE:-}" ]; then printf '%s' "$ENV_CRYPTO_PASSPHRASE"; return 0; fi
  if [ -n "${ENV_CRYPTO_PASSPHRASE_FILE:-}" ]; then
    [ -f "$ENV_CRYPTO_PASSPHRASE_FILE" ] || die "ENV_CRYPTO_PASSPHRASE_FILE does not exist"
    # Strip a single trailing newline only; preserve everything else verbatim.
    printf '%s' "$(cat -- "$ENV_CRYPTO_PASSPHRASE_FILE")"
    return 0
  fi
  die "openssl backend needs ENV_CRYPTO_PASSPHRASE or ENV_CRYPTO_PASSPHRASE_FILE"
}

# --------------------------------------------------------------------------
# openssl backend
#
# File layout:
#   line 1   magic
#   line 2+  base64 of AES-256-CBC(PBKDF2-HMAC-SHA512(pass, random salt, 600k))
#
# The encrypted plaintext is itself prefixed with a keyed integrity canary:
#   #env-crypto-integrity:v1:sha256=<hex of the dotenv body>
#   <dotenv body>
#
# Why a sealed canary rather than an encrypt-then-MAC over the ciphertext:
# `openssl dgst -macopt hexkey:` and `openssl kdf -kdfopt pass:` both require
# the key on the command line, where any local process can read it out of
# /proc/<pid>/cmdline. `openssl enc -pass env:` does not. Sealing the digest
# inside the ciphertext gives the same tamper detection without ever putting
# key material in argv: CBC bit-flipping garbles the target block wholesale
# and cannot produce a body whose SHA-256 matches an attacker-chosen canary
# line without the key.
# --------------------------------------------------------------------------

openssl_encrypt() {
  local plaintext_path=$1 out_path=$2 digest sealed
  openssl_is_usable || die "the openssl backend needs an \`openssl enc\` that supports -pbkdf2 (found: $(openssl version 2>/dev/null || echo none)). Use the age backend instead."
  digest=$(openssl dgst -sha256 -r < "$plaintext_path" | cut -d' ' -f1)
  sealed="$(scratch_dir)/sealed"
  ( umask 077
    printf '%s%s\n' "$INTEGRITY_PREFIX" "$digest" > "$sealed"
    cat -- "$plaintext_path" >> "$sealed" )
  {
    printf '%s\n' "$OPENSSL_MAGIC"
    ENV_CRYPTO_PASS_INTERNAL=$(openssl_passphrase) \
      openssl enc -aes-256-cbc -pbkdf2 -iter "$PBKDF2_ITER" -md sha512 -salt \
        -pass env:ENV_CRYPTO_PASS_INTERNAL -a -in "$sealed"
  } > "$out_path"
  rm -f -- "$sealed"
}

openssl_decrypt() {
  local in_path=$1 out_path=$2 sealed body_digest claimed first
  openssl_is_usable || die "the openssl backend needs an \`openssl enc\` that supports -pbkdf2 (found: $(openssl version 2>/dev/null || echo none))"
  sealed="$(scratch_dir)/unsealed"
  ( umask 077
    sed -n '2,$p' -- "$in_path" \
      | ENV_CRYPTO_PASS_INTERNAL=$(openssl_passphrase) \
        openssl enc -d -aes-256-cbc -pbkdf2 -iter "$PBKDF2_ITER" -md sha512 \
          -pass env:ENV_CRYPTO_PASS_INTERNAL -a -out "$sealed" ) \
    || die "decryption failed: wrong passphrase, or the ciphertext is corrupt"

  first=$(head -n 1 -- "$sealed" 2>/dev/null || true)
  case $first in
    "$INTEGRITY_PREFIX"*) claimed=${first#"$INTEGRITY_PREFIX"} ;;
    *) die "integrity check failed: no canary in the decrypted payload (wrong passphrase, or the ciphertext was tampered with)" ;;
  esac
  case $claimed in
    *[!0-9a-f]*|'') die "integrity check failed: malformed canary digest" ;;
  esac
  ( umask 077; sed -n '2,$p' -- "$sealed" > "$out_path" )
  body_digest=$(openssl dgst -sha256 -r < "$out_path" | cut -d' ' -f1)
  if [ "$body_digest" != "$claimed" ]; then
    rm -f -- "$out_path"
    die "integrity check failed: the ciphertext was modified after it was written"
  fi
  rm -f -- "$sealed"
}

# --------------------------------------------------------------------------
# backend dispatch
# --------------------------------------------------------------------------

backend_encrypt() {
  local backend=$1 plaintext_path=$2 out_path=$3
  case $backend in
    age)
      have age || die "\`age\` is not installed"
      local args=() r
      while IFS= read -r r; do [ -n "$r" ] && args+=(-r "$r"); done <<< "$(age_recipients)"
      age --armor "${args[@]}" -o "$out_path" "$plaintext_path"
      ;;
    sops)
      have sops || die "\`sops\` is not installed"
      have age  || die "\`age\` is not installed (sops backend encrypts to age recipients)"
      local recipients
      recipients=$(age_recipients | tr '\n' ',' | sed 's/,$//')
      # dotenv input/output keeps per-variable encryption and readable diffs.
      SOPS_AGE_RECIPIENTS="$recipients" sops --encrypt \
        --input-type dotenv --output-type dotenv \
        --age "$recipients" "$plaintext_path" > "$out_path"
      ;;
    openssl) openssl_encrypt "$plaintext_path" "$out_path" ;;
    *) die "unknown backend: $backend" ;;
  esac
}

backend_decrypt() {
  local backend=$1 in_path=$2 out_path=$3
  case $backend in
    age)
      have age || die "\`age\` is not installed"
      age --decrypt -i "$(age_identity_file)" -o "$out_path" "$in_path"
      ;;
    sops)
      have sops || die "\`sops\` is not installed"
      SOPS_AGE_KEY_FILE="$(age_identity_file)" sops --decrypt \
        --input-type dotenv --output-type dotenv "$in_path" > "$out_path"
      # SOPS exits 0 and passes a comment through VERBATIM when that comment's
      # GCM tag fails to verify ("possibly unencrypted comment"). Value and
      # sops_mac tampering are caught, but a modified comment is not — so
      # reject any line that still carries a SOPS envelope after decryption.
      if grep -q 'ENC\[AES256_GCM,' -- "$out_path" 2>/dev/null; then
        rm -f -- "$out_path"
        die "integrity check failed: decrypted output still contains SOPS envelopes (the ciphertext was modified after it was written)"
      fi
      ;;
    openssl) openssl_decrypt "$in_path" "$out_path" ;;
    *) die "unknown backend: $backend" ;;
  esac
}

# --------------------------------------------------------------------------
# guards
# --------------------------------------------------------------------------

assert_dec_ignored() {
  # Never write plaintext into a tree where git would track it.
  git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  local probe="env/dec/.env"
  if ! git -C "$ROOT" check-ignore -q "$probe" 2>/dev/null; then
    die "refusing to write plaintext: '$probe' is not gitignored. Run: $0 init"
  fi
  # A tracked file under env/dec/ means plaintext is already in history.
  if git -C "$ROOT" ls-files --error-unmatch env/dec >/dev/null 2>&1; then
    die "refusing to write plaintext: files under env/dec/ are tracked by git. Run: git rm -r --cached env/dec"
  fi
}

assert_not_ciphertext() {
  local path=$1 first
  first=$(head -n 1 -- "$path" 2>/dev/null || true)
  case $first in
    "$OPENSSL_MAGIC"*|"$AGE_MAGIC"*)
      die "${path#"$ROOT/"} already looks encrypted; refusing to double-encrypt" ;;
  esac
  if grep -qE '^(sops_version=|sops:)' -- "$path" 2>/dev/null; then
    die "${path#"$ROOT/"} already looks like a SOPS file; refusing to double-encrypt"
  fi
  if grep -qE '^[A-Za-z_][A-Za-z0-9_]*=ENC\[AES256_GCM,' -- "$path" 2>/dev/null; then
    die "${path#"$ROOT/"} already contains SOPS-encrypted values; refusing to double-encrypt"
  fi
}

assert_parses_as_dotenv() {
  local path=$1 n=0 line
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case $line in
      ''|'#'*|'export '*) continue ;;
    esac
    case $line in
      *=*) : ;;
      *) die "${path#"$ROOT/"}:$n is not a KEY=VALUE assignment, a comment, or blank" ;;
    esac
    local key=${line%%=*}
    case $key in
      *[!A-Za-z0-9_]*|[0-9]*|'') die "${path#"$ROOT/"}:$n has an invalid variable name" ;;
    esac
  done < "$path"
}

# --------------------------------------------------------------------------
# commands
# --------------------------------------------------------------------------

list_profiles() {
  [ -d "$ENC_DIR" ] || return 0
  local f base
  for f in "$ENC_DIR"/.env.enc "$ENC_DIR"/.env.*.enc; do
    [ -f "$f" ] || continue
    base=$(basename -- "$f")
    if [ "$base" = '.env.enc' ]; then printf 'default\n'
    else base=${base#.env.}; printf '%s\n' "${base%.enc}"; fi
  done | sort -u
}

cmd_init() {
  mkdir -p "$ENC_DIR" "$DEC_DIR"
  chmod 700 "$DEC_DIR"
  [ -f "$ENC_DIR/.gitkeep" ] || : > "$ENC_DIR/.gitkeep"

  # env/dec is never committed; the ignore file lives inside it so the rule
  # travels with the directory and cannot be lost from a root .gitignore edit.
  cat > "$DEC_DIR/.gitignore" <<'IGNORE'
# Decrypted secrets. Nothing in this directory is ever committed,
# including this file's siblings. Managed by scripts/env-crypto.sh.
*
!.gitignore
IGNORE

  # Two rules, and the second one is the non-obvious half. Most of these repos
  # already carry a broad `.env.*` ignore, and gitignore patterns without a
  # slash match a BASENAME at any depth — so `.env.*` silently swallows
  # `env/enc/.env.enc`. The ciphertext is meant to be committed, so it has to
  # be re-included explicitly or the whole scheme quietly stores nothing.
  local block
  block=$(printf '%s\n' \
    '' \
    '# env-crypto: decrypted secrets, never committed' \
    'env/dec/' \
    '# ...but the ENCRYPTED files must be committable. A broad `.env.*` rule' \
    '# elsewhere in this file would otherwise match env/enc/.env.enc by' \
    '# basename and silently exclude it.' \
    '!env/enc/**')
  [ -f "$ROOT/.gitignore" ] || : > "$ROOT/.gitignore"
  if ! grep -qxF '!env/enc/**' "$ROOT/.gitignore"; then
    printf '%s\n' "$block" >> "$ROOT/.gitignore"
    info "wired env/dec + env/enc rules into .gitignore"
  fi

  # Prove it rather than assume it: a negation cannot re-include a file whose
  # PARENT directory is excluded, so verify against the real ignore engine.
  if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if git -C "$ROOT" check-ignore -q 'env/enc/.env.enc' 2>/dev/null; then
      die "env/enc/.env.enc is still gitignored after init — the ciphertext could never be committed. Check for a rule excluding the env/ or env/enc/ directory itself."
    fi
  fi

  if [ ! -f "$ENC_DIR/.recipients" ]; then
    cat > "$ENC_DIR/.recipients" <<'RECIPIENTS'
# age recipients that can decrypt this repository's env files.
# One per line. Add the CI key here too, or CI cannot decrypt.
# Generate one with:  scripts/env-crypto.sh keygen
RECIPIENTS
    info "created env/enc/.recipients — add at least one age recipient"
  fi

  ok "initialized env/enc and env/dec in ${ROOT##*/}"
  info "next: put plaintext in env/dec/.env, then run: $0 encrypt"
}

cmd_keygen() {
  have age-keygen || die "\`age-keygen\` is not installed"
  local target=${ENV_CRYPTO_AGE_KEY_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/benefactor/age.key}
  [ -f "$target" ] && die "an identity already exists at $target; refusing to overwrite"
  mkdir -p "$(dirname -- "$target")"
  ( umask 077; age-keygen -o "$target" 2>/dev/null )
  chmod 600 "$target"
  ok "wrote a new age identity to $target (mode 0600)"
  info "public recipient — add this line to env/enc/.recipients in each repo:"
  age-keygen -y "$target"
}

cmd_encrypt() {
  local profile=${1:-default}
  validate_profile "$profile"
  local src dst backend
  src=$(profile_dec_path "$profile")
  dst=$(profile_enc_path "$profile")
  [ -f "$src" ] || die "nothing to encrypt: ${src#"$ROOT/"} does not exist"
  assert_not_ciphertext "$src"
  assert_parses_as_dotenv "$src"
  backend=$(resolve_backend_for_write)
  mkdir -p "$ENC_DIR"
  local tmp; tmp="$(scratch_dir)/out"
  backend_encrypt "$backend" "$src" "$tmp"
  [ -s "$tmp" ] || die "backend produced an empty ciphertext; refusing to write"
  mv -- "$tmp" "$dst"
  chmod 644 "$dst"
  ok "encrypted [$profile] with $backend -> ${dst#"$ROOT/"}"
}

cmd_decrypt() {
  local profile=${1:-default}
  validate_profile "$profile"
  local src dst backend
  src=$(profile_enc_path "$profile")
  dst=$(profile_dec_path "$profile")
  [ -f "$src" ] || die "no ciphertext for profile '$profile' at ${src#"$ROOT/"}"
  assert_dec_ignored
  backend=$(detect_ciphertext_backend "$src")
  mkdir -p "$DEC_DIR"; chmod 700 "$DEC_DIR"
  local tmp; tmp="$(scratch_dir)/plain"
  ( umask 077; backend_decrypt "$backend" "$src" "$tmp" )
  [ -s "$tmp" ] || die "decryption produced an empty file; refusing to write"
  assert_parses_as_dotenv "$tmp"
  ( umask 077; cat -- "$tmp" > "$dst" )
  chmod 600 "$dst"
  ok "decrypted [$profile] with $backend -> ${dst#"$ROOT/"} (mode 0600, $(grep -cvE '^[[:space:]]*(#|$)' -- "$dst" | head -1) variables)"
}

cmd_edit() {
  local profile=${1:-default}
  validate_profile "$profile"
  local src editor tmp before after
  src=$(profile_enc_path "$profile")
  editor=${EDITOR:-${VISUAL:-vi}}
  tmp="$(scratch_dir)/edit.env"
  if [ -f "$src" ]; then
    ( umask 077; backend_decrypt "$(detect_ciphertext_backend "$src")" "$src" "$tmp" )
  else
    ( umask 077; : > "$tmp" )
    info "profile '$profile' does not exist yet; starting from an empty file"
  fi
  before=$(openssl dgst -sha256 -r < "$tmp" | cut -d' ' -f1)
  "$editor" "$tmp"
  after=$(openssl dgst -sha256 -r < "$tmp" | cut -d' ' -f1)
  if [ "$before" = "$after" ]; then info "no changes; ciphertext left untouched"; return 0; fi
  assert_parses_as_dotenv "$tmp"
  local backend out
  backend=$(if [ -f "$src" ]; then detect_ciphertext_backend "$src"; else resolve_backend_for_write; fi)
  out="$(scratch_dir)/edit.enc"
  backend_encrypt "$backend" "$tmp" "$out"
  [ -s "$out" ] || die "backend produced an empty ciphertext; original left untouched"
  mkdir -p "$ENC_DIR"; mv -- "$out" "$src"; chmod 644 "$src"
  ok "re-encrypted [$profile] with $backend"
}

cmd_run() {
  local profile=default
  while [ $# -gt 0 ]; do
    case $1 in
      --profile) profile=${2:-}; shift 2 ;;
      --)        shift; break ;;
      *)         die "usage: $0 run [--profile P] -- <command> [args...]" ;;
    esac
  done
  [ $# -gt 0 ] || die "usage: $0 run [--profile P] -- <command> [args...]"
  validate_profile "$profile"
  local src tmp
  src=$(profile_enc_path "$profile")
  [ -f "$src" ] || die "no ciphertext for profile '$profile'"
  tmp="$(scratch_dir)/run.env"
  ( umask 077; backend_decrypt "$(detect_ciphertext_backend "$src")" "$src" "$tmp" )
  assert_parses_as_dotenv "$tmp"
  # Plaintext exists only under the 0700 scratch dir, which the EXIT trap wipes.
  set -o allexport
  # shellcheck disable=SC1090
  . "$tmp"
  set +o allexport
  rm -f -- "$tmp"
  exec "$@"
}

cmd_verify() {
  local failures=0 profile
  local profiles; profiles=$(list_profiles)
  [ -n "$profiles" ] || { warn "no encrypted profiles found under env/enc"; return 0; }
  while IFS= read -r profile; do
    [ -n "$profile" ] || continue
    local src backend tmp
    src=$(profile_enc_path "$profile")
    if ! backend=$(detect_ciphertext_backend "$src" 2>/dev/null); then
      log "  ${C_RED}FAIL${C_OFF} $profile — unrecognized ciphertext format"; failures=$((failures + 1)); continue
    fi
    tmp="$(scratch_dir)/verify.$profile"
    if ! ( umask 077; backend_decrypt "$backend" "$src" "$tmp" ) 2>/dev/null; then
      log "  ${C_RED}FAIL${C_OFF} $profile ($backend) — decryption failed"; failures=$((failures + 1)); continue
    fi
    if ! assert_parses_as_dotenv "$tmp" 2>/dev/null; then
      log "  ${C_RED}FAIL${C_OFF} $profile ($backend) — plaintext is not valid dotenv"; failures=$((failures + 1)); continue
    fi
    local count; count=$(grep -cvE '^[[:space:]]*(#|$)' -- "$tmp" | head -1)
    log "  ${C_GRN}ok${C_OFF}   $profile ($backend, $count variables)"
    rm -f -- "$tmp"
  done <<< "$profiles"
  [ "$failures" -eq 0 ] || die "$failures profile(s) failed verification"
  ok "all profiles decrypt and parse"
}

cmd_rotate() {
  local target=${ENV_CRYPTO_BACKEND:-}
  [ -n "$target" ] || die "set ENV_CRYPTO_BACKEND to the backend you are rotating to"
  local profiles; profiles=$(list_profiles)
  [ -n "$profiles" ] || die "no profiles to rotate"
  local profile
  while IFS= read -r profile; do
    [ -n "$profile" ] || continue
    local src tmp out from
    src=$(profile_enc_path "$profile")
    from=$(detect_ciphertext_backend "$src")
    tmp="$(scratch_dir)/rot.$profile"; out="$(scratch_dir)/rot.$profile.enc"
    ( umask 077; backend_decrypt "$from" "$src" "$tmp" )
    assert_parses_as_dotenv "$tmp"
    backend_encrypt "$target" "$tmp" "$out"
    [ -s "$out" ] || die "rotation produced empty ciphertext for '$profile'; nothing was overwritten"
    mv -- "$out" "$src"; chmod 644 "$src"
    rm -f -- "$tmp"
    ok "rotated [$profile] $from -> $target"
  done <<< "$profiles"
  info "rotation changed ciphertext only. Rotate the underlying SECRET VALUES separately if a key was exposed."
}

cmd_clean() {
  [ -d "$DEC_DIR" ] || { info "nothing to clean"; return 0; }
  local f n=0 stranded=0
  for f in "$DEC_DIR"/.env "$DEC_DIR"/.env.*; do
    [ -f "$f" ] || continue
    case $(basename -- "$f") in .gitignore) continue ;; esac
    # Truncate FIRST. On a filesystem that permits writes but not unlink — a
    # bind mount, a sandboxed bridge — the secret still has to stop existing
    # even though the directory entry cannot be removed.
    : > "$f" 2>/dev/null || true
    if rm -f -- "$f" 2>/dev/null; then n=$((n + 1)); else stranded=$((stranded + 1)); fi
  done
  if [ "$stranded" -gt 0 ]; then
    ok "wiped $((n + stranded)) decrypted file(s) from env/dec"
    warn "$stranded file(s) could not be unlinked on this filesystem; they were truncated to empty instead"
  else
    ok "removed $n decrypted file(s) from env/dec"
  fi
}

cmd_doctor() {
  log "env-crypto $ENV_CRYPTO_VERSION"
  log "repository: $ROOT"
  log ""
  log "backends:"
  if have sops && have age; then log "  ${C_GRN}available${C_OFF}   sops   $(sops --version 2>/dev/null | head -1)"
  elif have sops;            then log "  ${C_YLW}partial${C_OFF}     sops   installed, but \`age\` is missing"
  else                            log "  ${C_DIM}missing${C_OFF}     sops"; fi
  if have age; then log "  ${C_GRN}available${C_OFF}   age    $(age --version 2>/dev/null | head -1)"
  else              log "  ${C_DIM}missing${C_OFF}     age    install: brew install age | apt install age"; fi
  if openssl_is_usable; then log "  ${C_GRN}available${C_OFF}   openssl $(openssl version 2>/dev/null)"
  else log "  ${C_YLW}unusable${C_OFF}    openssl $(openssl version 2>/dev/null || echo 'not found') — needs OpenSSL 3.x with \`openssl kdf\`"; fi
  log ""
  log "key material:"
  if [ -n "${ENV_CRYPTO_AGE_KEY:-}" ]; then log "  ${C_GRN}present${C_OFF}     age identity from ENV_CRYPTO_AGE_KEY (in-memory)"
  else
    local kf=${ENV_CRYPTO_AGE_KEY_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/benefactor/age.key}
    if [ -f "$kf" ]; then
      local mode; mode=$(stat -c '%a' "$kf" 2>/dev/null || stat -f '%Lp' "$kf" 2>/dev/null || echo '?')
      if [ "$mode" = '600' ] || [ "$mode" = '400' ]; then log "  ${C_GRN}present${C_OFF}     age identity at $kf (mode $mode)"
      else log "  ${C_RED}insecure${C_OFF}    age identity at $kf has mode $mode — run: chmod 600 '$kf'"; fi
    else log "  ${C_YLW}absent${C_OFF}      no age identity at $kf — run: $0 keygen"; fi
  fi
  if [ -n "${ENV_CRYPTO_PASSPHRASE:-}${ENV_CRYPTO_PASSPHRASE_FILE:-}" ]; then log "  ${C_GRN}present${C_OFF}     openssl passphrase configured"
  else log "  ${C_DIM}absent${C_OFF}      no openssl passphrase configured"; fi
  log ""
  log "recipients:"
  if [ -f "$ENC_DIR/.recipients" ]; then
    # grep -c prints 0 AND exits 1 when nothing matches, so `|| echo 0`
    # would append a second line; take the first line instead.
    local rc; rc=$(grep -cE '^(age1|ssh-)' -- "$ENC_DIR/.recipients" 2>/dev/null | head -1)
    rc=${rc:-0}
    if [ "$rc" -gt 0 ]; then log "  ${C_GRN}$rc configured${C_OFF} in env/enc/.recipients"
    else log "  ${C_YLW}none${C_OFF}        env/enc/.recipients has no age1/ssh- entries"; fi
  else log "  ${C_YLW}absent${C_OFF}      env/enc/.recipients — run: $0 init"; fi
  log ""
  log "repository hygiene:"
  if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if git -C "$ROOT" check-ignore -q 'env/dec/.env' 2>/dev/null; then log "  ${C_GRN}ok${C_OFF}          env/dec is gitignored"
    else log "  ${C_RED}UNSAFE${C_OFF}      env/dec is NOT gitignored — run: $0 init"; fi
    local tracked; tracked=$(git -C "$ROOT" ls-files 'env/dec' | head -1 || true)
    if [ -n "$tracked" ]; then log "  ${C_RED}UNSAFE${C_OFF}      plaintext is tracked: $tracked — run: git rm -r --cached env/dec"
    else log "  ${C_GRN}ok${C_OFF}          no plaintext tracked under env/dec"; fi
    if git -C "$ROOT" check-ignore -q 'env/enc/.env.enc' 2>/dev/null; then
      log "  ${C_RED}UNSAFE${C_OFF}      env/enc/.env.enc is gitignored — ciphertext would never commit. Run: $0 init"
    else
      log "  ${C_GRN}ok${C_OFF}          env/enc ciphertext is committable"
    fi
    local stray; stray=$(git -C "$ROOT" ls-files | grep -E '(^|/)\.env$|(^|/)\.env\.[a-z]+$' | grep -v '\.example$' | head -3 || true)
    if [ -n "$stray" ]; then log "  ${C_RED}UNSAFE${C_OFF}      tracked plaintext dotenv outside env/: $(printf '%s' "$stray" | tr '\n' ' ')"
    else log "  ${C_GRN}ok${C_OFF}          no tracked plaintext dotenv elsewhere"; fi
  else log "  ${C_DIM}n/a${C_OFF}         not a git checkout"; fi
  log ""
  log "profiles:"
  local profiles; profiles=$(list_profiles)
  if [ -n "$profiles" ]; then
    local p; while IFS= read -r p; do
      [ -n "$p" ] || continue
      log "  $p ($(detect_ciphertext_backend "$(profile_enc_path "$p")" 2>/dev/null || echo unknown))"
    done <<< "$profiles"
  else log "  ${C_DIM}none${C_OFF}"; fi
}

usage() {
  cat >&2 <<USAGE
env-crypto $ENV_CRYPTO_VERSION — encrypted dotenv for benefactor-cc

  env/enc/.env.enc   committed ciphertext
  env/dec/.env       decrypted plaintext, gitignored, mode 0600

usage: scripts/env-crypto.sh <command> [profile]

  init                       create env/enc + env/dec and wire up .gitignore
  keygen                     generate an age identity and print its recipient
  encrypt [profile]          env/dec -> env/enc
  decrypt [profile]          env/enc -> env/dec
  edit    [profile]          decrypt to a temp file, \$EDITOR, re-encrypt
  run [--profile P] -- CMD   load vars into CMD's environment, no plaintext on disk
  verify                     decrypt and parse every profile (CI-safe, prints no values)
  rotate                     re-encrypt every profile with \$ENV_CRYPTO_BACKEND
  clean                      wipe env/dec
  list                       list profiles
  doctor                     report backends, keys, and repo hygiene

backends: sops (sops+age) | age | openssl   — set \$ENV_CRYPTO_BACKEND to choose
USAGE
}

main() {
  local cmd=${1:-}
  [ $# -gt 0 ] && shift || true
  case $cmd in
    init)     cmd_init ;;
    keygen)   cmd_keygen ;;
    encrypt)  cmd_encrypt "${1:-default}" ;;
    decrypt)  cmd_decrypt "${1:-default}" ;;
    edit)     cmd_edit "${1:-default}" ;;
    run)      cmd_run "$@" ;;
    verify)   cmd_verify ;;
    rotate)   cmd_rotate ;;
    clean)    cmd_clean ;;
    list)     list_profiles ;;
    doctor)   cmd_doctor ;;
    version|--version) printf '%s\n' "$ENV_CRYPTO_VERSION" ;;
    ''|help|--help|-h) usage; [ -z "$cmd" ] && exit 2 || exit 0 ;;
    *)        die "unknown command: $cmd (try: $0 help)" ;;
  esac
}

main "$@"
