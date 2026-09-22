#!/usr/bin/env bash
# Regression checks for the privileged paths in kali-update.sh.
# Sourced with KALI_UPDATE_SOURCE_ONLY=1 so the updater itself does not run.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export KALI_UPDATE_SOURCE_ONLY=1
# shellcheck source=/dev/null
source "$ROOT/kali-update.sh"

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}
ok() {
    printf '[OK] %s\n' "$1"
}

BASE=$(mktemp -d /root/kali-update-sectest.XXXXXX)
HOME_BASE=$(mktemp -d /home/kali-update-sectest.XXXXXX)
cleanup_fixtures() {
    rm -rf -- "$BASE" "$HOME_BASE"
    rm -f -- /tmp/kali-update-pwn-$$ /tmp/kali-update-cache-marker-$$
}
trap cleanup_fixtures EXIT

# --- log output does not pass terminal controls through ---
logged=$(log $'hello\033[31mred\033[0m')
case "$logged" in
    *$'\033'*) fail "log() kept an escape sequence" ;;
esac
case "$logged" in
    *hello*red*) ;;
    *) fail "log() dropped the visible text" ;;
esac
ok "log output strips terminal controls"

# --- PATH cannot select a caller-supplied apt-get ---
evil=$(mktemp -d "$BASE/evilbin.XXXXXX")
printf '#!/bin/sh\nprintf PWNED\\n\n' > "$evil/apt-get"
chmod 755 "$evil/apt-get"
PATH="$evil:/tmp"
_secure_path
[ "$PATH" = "/usr/sbin:/usr/bin:/sbin:/bin" ] || fail "PATH was not replaced"
got=$(command -v apt-get || true)
[ "$got" = /usr/bin/apt-get ] || fail "apt-get resolved to $got"
ok "PATH is fixed before privileged commands"

# --- configuration is not shell, and permissions are enforced ---
marker="/tmp/kali-update-pwn-$$"
rm -f -- "$marker"
confdir="$BASE/conf"
mkdir -m 755 "$confdir"
printf '%s\n' \
    'LOG_RETENTION=8' \
    'export KERNEL_KEEP=1' \
    'CLEAN_DEV_CACHES=false' \
    "touch $marker" \
    'LOG_RETENTION=$(touch '"$marker"')' \
    'KERNEL_KEEP=4; rm -rf /' \
    > "$confdir/kali-update.conf"
chmod 0644 "$confdir/kali-update.conf"
LOG_RETENTION=3
KERNEL_KEEP=2
CLEAN_DEV_CACHES=true
_load_config_file "$confdir/kali-update.conf"
[ "$LOG_RETENTION" = 8 ] || fail "LOG_RETENTION was not applied (got $LOG_RETENTION)"
[ "$KERNEL_KEEP" = 1 ] || fail "KERNEL_KEEP was not applied (got $KERNEL_KEEP)"
[ "$CLEAN_DEV_CACHES" = false ] || fail "CLEAN_DEV_CACHES was not applied"
[ ! -e "$marker" ] || fail "config file executed a command"
ok "config parser accepts KEY=value and does not execute the file"

chmod 0664 "$confdir/kali-update.conf"
if _config_file_trusted "$confdir/kali-update.conf" 0; then
    fail "group-writable config was accepted"
fi
chmod 0644 "$confdir/kali-update.conf"
if ! _config_file_trusted "$confdir/kali-update.conf" 0; then
    fail "root-owned mode 0644 config was rejected"
fi
ln -s "$confdir/kali-update.conf" "$confdir/link.conf"
if _config_file_trusted "$confdir/link.conf" 0; then
    fail "symlink config was accepted"
fi
chmod 0777 "$confdir"
if _config_file_trusted "$confdir/kali-update.conf" 0; then
    fail "config under a world-writable directory was accepted"
fi
chmod 0755 "$confdir"
ok "config permissions reject group-write, symlinks, and writable parents"

saved_home=$HOME
HOME="/tmp/kali-update-not-a-home-$$"
unset SUDO_USER || true
candidates=$(_config_candidates)
HOME=$saved_home
case "$candidates" in
    *"/tmp/kali-update-not-a-home-"*) fail "config candidates followed HOME" ;;
esac
case "$candidates" in
    *"/etc/kali-update.conf"*) ;;
    *) fail "system config path missing" ;;
esac
ok "config paths ignore HOME"

# --- NSS home and cache deletion ---
getent_bin=$(mktemp -d "$BASE/getent.XXXXXX")
cat > "$getent_bin/getent" << 'EOF'
#!/bin/sh
if [ "$1" = "passwd" ]; then
    case "$2" in
        badroot) printf '%s\n' 'badroot:x:0:0:Bad:/:'; exit 0 ;;
        badtmp) printf '%s\n' 'badtmp:x:1000:1000:Bad:/tmp/not-home:'; exit 0 ;;
        emptyhome) printf '%s\n' 'emptyhome:x:1000:1000:Bad::'; exit 0 ;;
        goodhome) printf '%s\n' "goodhome:x:1000:1000:Good:${KALI_UPDATE_TEST_HOME}:"; exit 0 ;;
    esac
fi
exec /usr/bin/getent "$@"
EOF
chmod 755 "$getent_bin/getent"
export KALI_UPDATE_TEST_HOME="$HOME_BASE"
PATH="$getent_bin:/usr/sbin:/usr/bin:/sbin:/bin"
if _validated_account_home badroot >/dev/null; then
    fail "home / was accepted"
fi
if _validated_account_home badtmp >/dev/null; then
    fail "home outside /root and /home was accepted"
fi
if _validated_account_home emptyhome >/dev/null; then
    fail "empty home was accepted"
fi
got_home=$(_validated_account_home goodhome)
[ "$got_home" = "$HOME_BASE" ] || fail "expected home was rejected ($got_home)"
_secure_path
ok "passwd home is limited to /root and /home"

mkdir -p "$HOME_BASE/.cache/pip"
printf 'keep\n' > "$HOME_BASE/.cache/pip/data"
if ! _safe_rm_cache_dir "$HOME_BASE" pip; then
    fail "real cache directory was refused"
fi
[ ! -e "$HOME_BASE/.cache/pip" ] || fail "cache directory was not removed"
marker_dir="$BASE/marker"
mkdir -p "$marker_dir"
printf 'keep\n' > "$marker_dir/keep"
mkdir -p "$HOME_BASE/.cache"
ln -s "$marker_dir" "$HOME_BASE/.cache/pip"
if _safe_rm_cache_dir "$HOME_BASE" pip; then
    fail "symlinked cache was removed"
fi
[ -f "$marker_dir/keep" ] || fail "symlinked cache deletion followed the link"
if _safe_rm_cache_dir / pip; then
    fail "cache deletion accepted home /"
fi
ok "cache deletion refuses symlinks and unexpected homes"

# --- keyring pin: untrusted bytes are not installed; pinned bytes are ---
saved_sha=("${KALI_KEYRING_SHA256[@]}")
saved_fprs=("${KALI_KEYRING_PRIMARY_FPRS[@]}")
saved_required=$KALI_KEYRING_REQUIRED_FPR
ringdir=$(mktemp -d "$BASE/keyring.XXXXXX")
printf 'not a keyring\n' > "$ringdir/bad.gpg"
if _keyring_download_trusted "$ringdir/bad.gpg"; then
    fail "untrusted keyring bytes were accepted"
fi

gnupg_home=$(mktemp -d "$BASE/gnupg.XXXXXX")
chmod 700 "$gnupg_home"
GNUPGHOME="$gnupg_home" gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-gen-key 'Kali Update Test <kutest@example.com>' rsa2048 cert never >/dev/null
test_fpr=$(GNUPGHOME="$gnupg_home" gpg --batch --with-colons --fingerprint | awk -F: '$1=="fpr" { print $10; exit }')
[ -n "$test_fpr" ] || fail "test key fingerprint missing"
GNUPGHOME="$gnupg_home" gpg --batch --export "$test_fpr" > "$ringdir/pub.gpg"
GNUPGHOME="$gnupg_home" gpg --batch --no-default-keyring --keyring "$ringdir/test.gpg" --import "$ringdir/pub.gpg" >/dev/null
test_sum=$(sha256sum -- "$ringdir/test.gpg" | awk 'NR==1 { print $1 }')
KALI_KEYRING_SHA256=("$test_sum")
KALI_KEYRING_PRIMARY_FPRS=("$test_fpr")
KALI_KEYRING_REQUIRED_FPR=$test_fpr
if ! _keyring_download_trusted "$ringdir/test.gpg"; then
    fail "pinned test keyring was rejected"
fi
saved_home=$HOME
HOME="/tmp/kali-update-missing-home-$$"
if ! _keyring_download_trusted "$ringdir/test.gpg"; then
    HOME=$saved_home
    fail "keyring check followed HOME"
fi
HOME=$saved_home

installed="$ringdir/installed.gpg"
printf 'OLD\n' > "$installed"
curl_bin=$(mktemp -d "$BASE/curl.XXXXXX")
cat > "$curl_bin/curl" << 'EOF'
#!/bin/sh
out=""
prev=""
for arg in "$@"; do
    if [ "$prev" = "-o" ]; then
        out=$arg
    fi
    prev=$arg
done
[ -n "$out" ] || exit 1
cp -- "$KALI_UPDATE_CURL_FIXTURE" "$out"
EOF
chmod 755 "$curl_bin/curl"
export KALI_UPDATE_CURL_FIXTURE="$ringdir/bad.gpg"
PATH="$curl_bin:/usr/sbin:/usr/bin:/sbin:/bin"
KEYRING_PATH="$installed"
refresh_kali_keyring || true
[ "$(cat "$installed")" = "OLD" ] || fail "untrusted download replaced the keyring"
ok "missing or invalid keyring material does not replace the installed keyring"

export KALI_UPDATE_CURL_FIXTURE="$ringdir/test.gpg"
refresh_kali_keyring || fail "pinned keyring refresh failed"
cmp -s "$ringdir/test.gpg" "$installed" || fail "pinned keyring was not installed"
ok "pinned keyring is installed only after the hash and fingerprint checks"

KALI_KEYRING_SHA256=("${saved_sha[@]}")
KALI_KEYRING_PRIMARY_FPRS=("${saved_fprs[@]}")
KALI_KEYRING_REQUIRED_FPR=$saved_required
_secure_path
live=$(mktemp "$BASE/live.XXXXXX")
curl -fsSL --max-time 30 -o "$live" https://archive.kali.org/archive-keyring.gpg || fail "could not download the published keyring"
if ! _keyring_download_trusted "$live"; then
    fail "published archive-keyring.gpg does not match the pins in kali-update.sh"
fi
ok "published Kali archive keyring matches the script pins"

# --- sources.list restore is atomic and failure is visible ---
aptdir=$(mktemp -d "$BASE/apt.XXXXXX")
sources="$aptdir/sources.list"
backup="$aptdir/backup"
original='deb https://http.kali.org/kali kali-rolling main contrib non-free non-free-firmware'
fallback='deb http://ftp.halifax.rwth-aachen.de/kali kali-rolling main contrib non-free non-free-firmware'
printf '%s\n' "$original" > "$backup"
printf '%s\n' "$fallback" > "$sources"
chmod 0644 "$backup" "$sources"
KALI_SOURCES_LIST=$sources
KALI_MIRROR_TEMPORARY=true
KALI_SOURCES_BACKUP=$backup
EXIT_CODE=0
restore_temporary_kali_sources || fail "restore of a valid backup failed"
grep -q 'https://http.kali.org/kali' "$sources" || fail "sources.list was not restored"
[ "$KALI_MIRROR_TEMPORARY" = false ] || fail "temporary mirror flag stayed set"
[ ! -e "$backup" ] || fail "backup was kept after a successful restore"
printf 'deb https://http.kali.org/kali kali-rolling main%s\n' $'\033[31m' > "$sources"
if _kali_sources_ok "$sources"; then
    fail "sources.list with a terminal control was accepted"
fi
printf '%s\n' "$fallback" > "$sources"
ok "sources.list restore replaces the HTTP fallback"

printf '%s\n' "$original" > "$backup"
printf '%s\n' "$fallback" > "$sources"
KALI_MIRROR_TEMPORARY=true
KALI_SOURCES_BACKUP=$backup
EXIT_CODE=0
mv_bin=$(mktemp -d "$BASE/mv.XXXXXX")
printf '#!/bin/sh\nexit 1\n' > "$mv_bin/mv"
chmod 755 "$mv_bin/mv"
PATH="$mv_bin:/usr/sbin:/usr/bin:/sbin:/bin"
if restore_temporary_kali_sources; then
    fail "restore succeeded when mv failed"
fi
[ "$EXIT_CODE" -ge 1 ] || fail "failed restore did not record a failure"
grep -q 'http://ftp.halifax.rwth-aachen.de/kali' "$sources" || fail "failed restore changed sources.list"
[ -f "$backup" ] || fail "backup was deleted when restore failed"
_secure_path
ok "failed sources.list restore is a recorded failure and keeps the backup"

ln -s "$sources" "$aptdir/sources.link"
newfile="$aptdir/new"
printf '%s\n' "$original" > "$newfile"
if _atomic_replace_file "$newfile" "$aptdir/sources.link"; then
    fail "atomic replace followed a symlink"
fi
ok "atomic replace refuses a symlink"

# Interrupted run: the exit path restores, and a failed restore is non-zero.
printf '%s\n' "$original" > "$backup"
printf '%s\n' "$fallback" > "$sources"
KALI_MIRROR_TEMPORARY=true
KALI_SOURCES_BACKUP=$backup
LOCKFILE=
set +e
(
    cleanup 0
)
interrupt_rc=$?
set -e
[ "$interrupt_rc" -eq 0 ] || fail "cleanup exit after restore was $interrupt_rc"
grep -q 'https://http.kali.org/kali' "$sources" || fail "interrupt path did not restore sources.list"
ok "interrupt path restores sources.list"

printf '%s\n' "$original" > "$backup"
printf '%s\n' "$fallback" > "$sources"
KALI_MIRROR_TEMPORARY=true
KALI_SOURCES_BACKUP=$backup
LOCKFILE=
PATH="$mv_bin:/usr/sbin:/usr/bin:/sbin:/bin"
set +e
(
    cleanup 0
)
interrupt_rc=$?
set -e
_secure_path
[ "$interrupt_rc" -ne 0 ] || fail "cleanup reported success when restore failed"
grep -q 'http://ftp.halifax.rwth-aachen.de/kali' "$sources" || fail "failed interrupt restore changed sources.list"
[ -f "$backup" ] || fail "interrupt path deleted the backup after a failed restore"
ok "interrupt path reports failure when sources.list cannot be restored"

printf '[OK] security regressions passed\n'
