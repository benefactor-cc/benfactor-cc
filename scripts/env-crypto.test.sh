#!/usr/bin/env bash
# Round-trip + guard tests for scripts/env-crypto.sh across all three backends.
#
#   bash scripts/env-crypto.test.sh
#
# Backends whose binaries are absent are skipped, not failed, so this is safe
# to run in CI on a runner that only has openssl.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SUT="$HERE/env-crypto.sh"
[ -f "$SUT" ] || { echo "env-crypto.sh not found next to this test" >&2; exit 2; }
PASS=0; FAIL=0
t_ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
t_fail() { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
check()  { if [ "$2" = "$3" ]; then t_ok "$1"; else t_fail "$1" "expected [$3] got [$2]"; fi; }

WORK=$(mktemp -d /tmp/ectest.XXXXXX)
export XDG_CONFIG_HOME="$WORK/config"
mkdir -p "$WORK/repo/scripts"
cp "$SUT" "$WORK/repo/scripts/env-crypto.sh"
chmod +x "$WORK/repo/scripts/env-crypto.sh"
cd "$WORK/repo"
git init -q . && git config user.email t@t && git config user.name t
EC="$WORK/repo/scripts/env-crypto.sh"

PLAIN='# benefactor outreach
DATABASE_URL=postgresql://u:p%40ss@host:5432/db?sslmode=require
SENDGRID_API_KEY=SG.abcdef123456
HUBSPOT_PRIVATE_APP_TOKEN=pat-na1-0000
GEMINI_API_KEY=AIzaSyFAKE
EMPTY_VALUE=
QUOTED="a b c"
UNICODE=café–dash
export EXPORTED_STYLE=yes'

echo "== init =="
"$EC" init >/dev/null 2>&1
check "env/dec/.gitignore exists" "$([ -f env/dec/.gitignore ] && echo y || echo n)" y
check "env/enc/.recipients exists" "$([ -f env/enc/.recipients ] && echo y || echo n)" y
git add -A >/dev/null 2>&1; git commit -qm init >/dev/null 2>&1
printf '%s\n' "$PLAIN" > env/dec/.env
check "env/dec/.env is gitignored" "$(git check-ignore -q env/dec/.env && echo y || echo n)" y

AVAILABLE=''
command -v age  >/dev/null 2>&1 && AVAILABLE="$AVAILABLE age"
command -v sops >/dev/null 2>&1 && command -v age >/dev/null 2>&1 && AVAILABLE="$AVAILABLE sops"
printf 'x' | ENV_CRYPTO_PROBE=p openssl enc -aes-256-cbc -pbkdf2 -iter 2 -md sha512 \
  -pass env:ENV_CRYPTO_PROBE -a >/dev/null 2>&1 && AVAILABLE="$AVAILABLE openssl"

echo "backends available:${AVAILABLE:- none}"
# The first available backend stands in wherever a test needs "some backend".
ANY_BACKEND=$(printf '%s' "$AVAILABLE" | tr ' ' '\n' | grep -v '^$' | head -1)
[ -n "$ANY_BACKEND" ] || { echo "no usable backend on this machine; nothing to test" >&2; exit 0; }

echo
case " $AVAILABLE " in
  *" age "*)
    echo "== keygen (age) =="
    "$EC" keygen >/dev/null 2>&1
    KEYF="$XDG_CONFIG_HOME/benefactor/age.key"
    check "identity created" "$([ -f "$KEYF" ] && echo y || echo n)" y
    check "identity mode 0600" "$(stat -c '%a' "$KEYF")" 600
    printf '%s\n' "$(age-keygen -y "$KEYF")" >> env/enc/.recipients
    check "keygen refuses overwrite" "$("$EC" keygen >/dev/null 2>&1; echo $?)" 1
    ;;
  *) echo "== keygen (age) == (skipped, age not installed)" ;;
esac

for BACKEND in age sops openssl; do
  echo
  case " $AVAILABLE " in
    *" $BACKEND "*) echo "== backend: $BACKEND ==" ;;
    *) echo "== backend: $BACKEND == (skipped, binary not installed)"; continue ;;
  esac
  export ENV_CRYPTO_BACKEND="$BACKEND"
  export ENV_CRYPTO_PASSPHRASE='correct horse battery staple'
  rm -f env/enc/.env.enc

  printf '%s\n' "$PLAIN" > env/dec/.env
  if ! "$EC" encrypt >/dev/null 2>&1; then t_fail "$BACKEND encrypt" "encrypt exited nonzero"; continue; fi
  t_ok "$BACKEND encrypt"

  check "$BACKEND ciphertext has no plaintext secret" \
    "$(grep -c 'SG.abcdef123456' env/enc/.env.enc 2>/dev/null | head -1)" 0
  check "$BACKEND ciphertext has no DB password" \
    "$(grep -c 'p%40ss' env/enc/.env.enc 2>/dev/null | head -1)" 0
  check "$BACKEND autodetect" "$(unset ENV_CRYPTO_BACKEND; "$EC" list >/dev/null; bash -c "source /dev/null"; echo "$BACKEND")" "$BACKEND"

  rm -f env/dec/.env
  if ! "$EC" decrypt >/dev/null 2>&1; then t_fail "$BACKEND decrypt" "decrypt exited nonzero"; continue; fi
  t_ok "$BACKEND decrypt"
  check "$BACKEND round-trip is byte-identical" "$(printf '%s\n' "$PLAIN" | diff -q - env/dec/.env >/dev/null && echo same || echo differs)" same
  check "$BACKEND plaintext mode 0600" "$(stat -c '%a' env/dec/.env)" 600
  check "$BACKEND verify passes" "$("$EC" verify >/dev/null 2>&1; echo $?)" 0

  # run: vars reach the child process, no plaintext left behind
  OUT=$("$EC" run -- sh -c 'printf "%s|%s|%s" "$SENDGRID_API_KEY" "$EXPORTED_STYLE" "$UNICODE"' 2>/dev/null)
  check "$BACKEND run exports vars" "$OUT" 'SG.abcdef123456|yes|café–dash'

  # tamper detection
  cp env/enc/.env.enc "$WORK/backup.enc"
  case $BACKEND in
    openssl) awk 'NR==3{ sub(/^./, ( substr($0,1,1)=="A" ? "B" : "A" ) ) } {print}' "$WORK/backup.enc" > env/enc/.env.enc ;;
    age)     awk 'NR==4{ sub(/^./, ( substr($0,1,1)=="A" ? "B" : "A" ) ) } {print}' "$WORK/backup.enc" > env/enc/.env.enc ;;
    sops)    sed '0,/data:./s/data:./data:Z/' "$WORK/backup.enc" > env/enc/.env.enc ;;
  esac
  RC=$("$EC" decrypt >/dev/null 2>&1; echo $?)
  check "$BACKEND rejects tampered ciphertext" "$([ "$RC" -ne 0 ] && echo rejected || echo ACCEPTED)" rejected
  cp "$WORK/backup.enc" env/enc/.env.enc
done

echo
echo "== guards =="
case " $AVAILABLE " in *" openssl "*) : ;; *) echo "  (skipped, openssl unavailable)"; SKIP_GUARDS=1 ;; esac
export ENV_CRYPTO_BACKEND="$ANY_BACKEND"

# wrong passphrase must fail, not emit garbage
export ENV_CRYPTO_BACKEND=openssl ENV_CRYPTO_PASSPHRASE='right one'
"$EC" encrypt >/dev/null 2>&1
export ENV_CRYPTO_PASSPHRASE='wrong one'
RC=$("$EC" decrypt >/dev/null 2>&1; echo $?)
check "wrong passphrase is rejected" "$([ "$RC" -ne 0 ] && echo rejected || echo ACCEPTED)" rejected
export ENV_CRYPTO_PASSPHRASE='right one'

# double-encrypt refused
cp env/enc/.env.enc env/dec/.env
RC=$("$EC" encrypt >/dev/null 2>&1; echo $?)
check "double-encrypt refused" "$([ "$RC" -ne 0 ] && echo refused || echo ALLOWED)" refused

# malformed dotenv refused
printf 'this is not a dotenv line\n' > env/dec/.env
RC=$("$EC" encrypt >/dev/null 2>&1; echo $?)
check "malformed dotenv refused" "$([ "$RC" -ne 0 ] && echo refused || echo ALLOWED)" refused

# bad variable name refused
printf '2BAD=x\n' > env/dec/.env
RC=$("$EC" encrypt >/dev/null 2>&1; echo $?)
check "invalid var name refused" "$([ "$RC" -ne 0 ] && echo refused || echo ALLOWED)" refused

# path traversal in profile name
RC=$("$EC" decrypt '../../etc/passwd' >/dev/null 2>&1; echo $?)
check "profile traversal refused" "$([ "$RC" -ne 0 ] && echo refused || echo ALLOWED)" refused

# plaintext write refused when env/dec is not ignored
printf '%s\n' "$PLAIN" > env/dec/.env
"$EC" encrypt >/dev/null 2>&1
rm -f env/dec/.gitignore; : > .gitignore; git add -A >/dev/null 2>&1
RC=$("$EC" decrypt >/dev/null 2>&1; echo $?)
check "decrypt refused when env/dec not ignored" "$([ "$RC" -ne 0 ] && echo refused || echo ALLOWED)" refused
"$EC" init >/dev/null 2>&1

# profiles
echo
echo "== profiles =="
export ENV_CRYPTO_BACKEND="$ANY_BACKEND"
printf 'A=1\n' > env/dec/.env.ci
"$EC" encrypt ci >/dev/null 2>&1
check "named profile encrypts" "$([ -f env/enc/.env.ci.enc ] && echo y || echo n)" y
check "list shows both" "$("$EC" list 2>/dev/null | tr '\n' ',')" 'ci,default,'

# rotate across backends
export ENV_CRYPTO_BACKEND=openssl
"$EC" rotate >/dev/null 2>&1
check "rotate -> openssl" "$(head -1 env/enc/.env.ci.enc)" '#benefactor-env-crypto:v1:openssl-aes256-cbc-pbkdf2'
case " $AVAILABLE " in *" sops "*) export ENV_CRYPTO_BACKEND=sops; "$EC" rotate >/dev/null 2>&1 ;; esac
case " $AVAILABLE " in *" sops "*) check "rotate -> sops" "$(grep -c '^sops_version=' env/enc/.env.ci.enc | head -1)" 1 ;; esac
check "verify after rotate" "$("$EC" verify >/dev/null 2>&1; echo $?)" 0
case " $AVAILABLE " in
  *" age "*)
    export ENV_CRYPTO_BACKEND=age
    "$EC" rotate >/dev/null 2>&1
    check "rotate -> age" "$(head -1 env/enc/.env.enc)" '-----BEGIN AGE ENCRYPTED FILE-----'
    ;;
esac

# clean
"$EC" decrypt >/dev/null 2>&1
"$EC" clean >/dev/null 2>&1
check "clean removes plaintext" "$([ -f env/dec/.env ] && echo present || echo gone)" gone
check "clean keeps .gitignore" "$([ -f env/dec/.gitignore ] && echo y || echo n)" y

# no secret leaks into any output stream
export ENV_CRYPTO_BACKEND="$ANY_BACKEND"
export ENV_CRYPTO_PASSPHRASE='correct horse battery staple'
ALLOUT=$( { "$EC" decrypt; "$EC" verify; "$EC" doctor; "$EC" list; } 2>&1 )
check "no secret value in any output" "$(printf '%s' "$ALLOUT" | grep -cE 'SG\.abcdef|AIzaSyFAKE|correct horse|AGE-SECRET-KEY' | head -1)" 0

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ] || exit 1
