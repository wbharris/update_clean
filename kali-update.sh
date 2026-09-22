#!/usr/bin/env bash
# Kali Linux - Complete Update & Cleanup Script
# Full system update + thorough cleanup for Kali Rolling
#
# Copyright (C) 2026 wbharris
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
# Usage: sudo ./kali-update.sh [--dry-run] [--no-kernel] [--help] [--version]
# Recommended: run weekly
# Configurable via env or /etc/kali-update.conf

set -euo pipefail
set -o errtrace

if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    printf '%s\n' "This script requires Bash 4+. Found: ${BASH_VERSION:-unknown}" >&2
    exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# ────────────────────────────────────────────────────────────────
# Defaults & Config
# ────────────────────────────────────────────────────────────────
DRY_RUN=false
SKIP_KERNEL=false
LOG_RETENTION=${LOG_RETENTION:-3}
KERNEL_KEEP=${KERNEL_KEEP:-2}
# Wipe regenerable pip/go/uv caches (large; next pip/go/uv job rebuilds them)
CLEAN_DEV_CACHES=${CLEAN_DEV_CACHES:-true}
VERSION=$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "unknown")
EXIT_CODE=0
KERNELS_REMOVED=false
REBOOT_REQUIRED_MTIME_BEFORE=0

# Colors (define before config load — load_config_files may warn)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()      { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
info()     { echo -e "${BLUE}[INFO]${NC} $1"; }
success()  { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warn()     { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error()    { echo -e "${RED}[ERROR]${NC} $1"; }

load_config_files() {
    local conf owner
    for conf in /etc/kali-update.conf "$HOME/.config/kali-update.conf" "$HOME/.kali-update.conf"; do
        [ -f "$conf" ] || continue
        if [[ "$conf" == /etc/* ]]; then
            owner=$(stat -c %u "$conf" 2>/dev/null || echo "invalid")
            if ! [[ "$owner" =~ ^[0-9]+$ ]] || [ "$owner" != "0" ]; then
                warn "Config $conf not owned by root (uid=$owner); skipping"
                continue
            fi
        fi
        # shellcheck source=/dev/null
        source "$conf"
    done
}

load_config_files

# Re-apply defaults so empty config values do not disable features
LOG_RETENTION=${LOG_RETENTION:-3}
KERNEL_KEEP=${KERNEL_KEEP:-2}
CLEAN_DEV_CACHES=${CLEAN_DEV_CACHES:-true}

_record_failure() { EXIT_CODE=$((EXIT_CODE + 1)); }
has_cmd() { command -v "$1" >/dev/null 2>&1; }

_is_truthy() {
    case "${1,,}" in
        true|yes|on|1) return 0 ;;
        *) return 1 ;;
    esac
}

# Remove regenerable toolchain caches only (not GOPATH sources or project trees).
clean_dev_caches() {
    local home dir cache size
    local -a homes=()
    local -a caches=(pip go-build uv)

    homes+=("/root")
    if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
        home=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)
        if [ -n "$home" ] && [ -d "$home" ]; then
            homes+=("$home")
        fi
    fi

    for home in "${homes[@]}"; do
        for cache in "${caches[@]}"; do
            dir="$home/.cache/$cache"
            [ -e "$dir" ] || continue
            size=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
            if $DRY_RUN; then
                info "DRY-RUN: Would remove $dir ($size)"
                continue
            fi
            info "Removing regenerable cache $dir ($size)"
            rm -rf "$dir" || warn "Failed to remove $dir"
        done
    done
}

# Versioned kernel packages only. '-' sits at the end of the class so it is
# literal (a mid-class '-' makes grep abort with "Invalid range end").
# Kali ships both linux-image-VERSION and linux-binary-VERSION.
_KERNEL_PKG_RE='^(linux-image(-unsigned)?|linux-binary)-[0-9][0-9A-Za-z.+-]*$'

list_installed_kernel_images() {
    dpkg-query -W -f='${Status}\t${Package}\n' 'linux-image-*' 'linux-binary-*' 2>/dev/null \
        | awk -F'\t' '$1 ~ /^(install|hold) ok installed/ {print $2}' \
        | grep -E "$_KERNEL_PKG_RE" \
        | grep -Ev -- '-(meta|dbg|dbgsym|rt|cloud|kvm|virtual)$' \
        | sort -V
}

kernel_pkg_version() {
    local pkg="$1"
    if [[ "$pkg" =~ ^linux-image-unsigned-(.+)$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    elif [[ "$pkg" =~ ^linux-(image|binary)-(.+)$ ]]; then
        printf '%s' "${BASH_REMATCH[2]}"
    fi
}

find_running_kernel_pkg() {
    local running_ver="$1"
    shift
    local pkg vmlinuz
    local -a candidates=("$@")

    [ -z "$running_ver" ] && return 1

    vmlinuz="/boot/vmlinuz-${running_ver}"
    if [ -f "$vmlinuz" ]; then
        pkg=$(dpkg-query -S "$vmlinuz" 2>/dev/null | awk -F: '{print $1}' | head -n1)
        if [ -n "$pkg" ]; then
            printf '%s' "$pkg"
            return 0
        fi
    fi

    if [ "${#candidates[@]}" -eq 0 ]; then
        mapfile -t candidates < <(list_installed_kernel_images)
    fi

    for pkg in "${candidates[@]}"; do
        if [[ "$pkg" == *"$running_ver"* ]]; then
            printf '%s' "$pkg"
            return 0
        fi
    done
    return 1
}

purge_kernel_related() {
    local pkg="$1"
    local ver suffix candidate related sibling

    ver=$(kernel_pkg_version "$pkg")
    [ -n "$ver" ] || return 0

    for sibling in "linux-image-${ver}" "linux-image-unsigned-${ver}" "linux-binary-${ver}"; do
        [ "$sibling" = "$pkg" ] && continue
        if dpkg-query -W -f='${Status}' "$sibling" 2>/dev/null | grep -q 'install ok installed'; then
            if $DRY_RUN; then
                info "DRY-RUN: Would purge $sibling"
            else
                apt-mark unhold "$sibling" 2>/dev/null || true
                apt-get purge -y "$sibling" 2>&1 | tee -a "${APT_LOG:-/dev/null}" || true
            fi
        fi
    done

    for suffix in headers modules-extra modules modules-unsigned; do
        candidate="linux-${suffix}-${ver}"
        if dpkg-query -W -f='${Status}' "$candidate" 2>/dev/null | grep -q 'install ok installed'; then
            if $DRY_RUN; then
                info "DRY-RUN: Would purge $candidate"
            else
                apt-get purge -y "$candidate" 2>&1 | tee -a "${APT_LOG:-/dev/null}" || true
            fi
        fi
    done
    while IFS= read -r related; do
        [ -z "$related" ] || [ "$related" = "$pkg" ] && continue
        if $DRY_RUN; then
            info "DRY-RUN: Would purge $related"
        else
            apt-get purge -y "$related" 2>&1 | tee -a "${APT_LOG:-/dev/null}" || true
        fi
    done < <(
        dpkg-query -W -f='${Package}\n' 2>/dev/null \
            | grep -E '^linux-(headers|modules)' \
            | grep -F -- "$ver" || true
    )
}

remove_old_kernels() {
    local -a kernels=() versions=() old_versions=()
    local running_pkg running_ver pkg ver delcount keep boot_kb seen

    if [ -d /boot ]; then
        boot_kb=$(df -B 1K /boot 2>/dev/null | awk 'NR==2 {print $4+0}')
        if [ "${boot_kb:-0}" -lt 10240 ]; then
            warn "Skipping kernel removal: /boot has less than 10 MB free"
            return 0
        fi
    fi

    mapfile -t kernels < <(list_installed_kernel_images)

    running_ver=$(uname -r 2>/dev/null || true)
    running_pkg=$(find_running_kernel_pkg "$running_ver" "${kernels[@]}" || true)
    if [ -z "$running_ver" ] && [ -n "$running_pkg" ]; then
        running_ver=$(kernel_pkg_version "$running_pkg")
    fi

    if [ -n "$running_pkg" ]; then
        info "Running kernel package: $running_pkg ($running_ver)"
    elif [ -n "$running_ver" ]; then
        warn "Could not match package for running kernel $running_ver; skipping kernel removal"
        return 0
    fi

    if [ "${#kernels[@]}" -eq 0 ]; then
        info "No versioned linux-image or linux-binary packages found."
        return 0
    fi

    seen=" "
    for pkg in "${kernels[@]}"; do
        ver=$(kernel_pkg_version "$pkg")
        [ -n "$ver" ] || continue
        [[ "$seen" == *" $ver "* ]] && continue
        seen+="$ver "
        if [ -n "$running_ver" ] && [ "$ver" = "$running_ver" ]; then
            continue
        fi
        versions+=("$ver")
    done

    if [ "${#versions[@]}" -eq 0 ]; then
        info "No old kernels to remove (only the running kernel is installed)."
        return 0
    fi

    mapfile -t old_versions < <(printf '%s\n' "${versions[@]}" | sort -V)

    keep="${KERNEL_KEEP:-2}"
    if [ "${#old_versions[@]}" -le "$keep" ]; then
        info "No old kernels to remove (keeping $keep beside running kernel)."
        return 0
    fi

    delcount=$(( ${#old_versions[@]} - keep ))
    if [ "$delcount" -lt 1 ] || [ "$delcount" -gt "${#old_versions[@]}" ]; then
        warn "Kernel removal count out of range; skipping"
        return 0
    fi

    KERNELS_REMOVED=true
    info "Kernel versions scheduled for removal ($delcount):"
    for ver in "${old_versions[@]:0:delcount}"; do
        info "  $ver"
    done

    for ver in "${old_versions[@]:0:delcount}"; do
        for pkg in "${kernels[@]}"; do
            [ "$(kernel_pkg_version "$pkg")" = "$ver" ] || continue
            if $DRY_RUN; then
                info "DRY-RUN: Would purge old kernel: $pkg"
                continue
            fi
            info "Purging old kernel: $pkg"
            apt-mark unhold "$pkg" 2>/dev/null || true
            apt-get purge -y "$pkg" 2>&1 | tee -a "${APT_LOG:-/dev/null}" || warn "Failed to purge $pkg"
            purge_kernel_related "$pkg"
        done
    done
}

# ────────────────────────────────────────────────────────────────
# CLI Parsing (do this very early, before logging or heavy work)
# ────────────────────────────────────────────────────────────────
usage() {
    cat << USAGE
Usage: sudo $0 [options]

Options:
  --dry-run       Simulate actions without making changes
  --no-kernel     Skip old kernel removal
  --last, --status  Show information from the last run
  --check, --doctor Run pre-flight checks only (no updates)
  --help, -h      Show this help
  --version, -v   Show version information

Environment / Config:
  LOG_RETENTION     Number of logs to keep (default: 3)
  KERNEL_KEEP       Kernels to keep besides running (default: 2)
  CLEAN_DEV_CACHES  Remove pip/go-build/uv caches (default: true)
USAGE
}


show_version() {
    echo "kali-update $VERSION"

    # Git commit (if available)
    if [ -d .git ]; then
        local commit
        commit=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
        echo "Commit: $commit"
    fi

    # Last run info if available
    local last_file="/var/lib/kali-update/last-run"
    if [ -f "$last_file" ]; then
        echo ""
        echo "Last run:"
        cat "$last_file" | sed 's/^/  /'
    fi
}

show_last_run() {
    local last_file="/var/lib/kali-update/last-run"
    if [ -f "$last_file" ]; then
        echo "Last run information:"
        cat "$last_file"
    else
        echo "No last-run record found."
    fi
}

run_preflight_checks() {
    echo "=== Pre-flight Checks ==="

    echo -n "Running as root: "
    if [ "$EUID" -eq 0 ]; then echo "OK"; else echo "FAIL (must be root)"; fi

    echo -n "Internet (archive.kali.org): "
    if timeout 5 bash -c "echo > /dev/tcp/archive.kali.org/443" 2>/dev/null; then
        echo "OK"
    else
        echo "FAIL (trying fallback)"
        if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
            echo "  Fallback OK (8.8.8.8)"
        else
            echo "  FAIL"
        fi
    fi

    for part in / /var /boot; do
        if [ -d "$part" ]; then
            local avail
            avail=$(df "$part" --output=avail | tail -n 1)
            echo -n "Disk space on $part: "
            if [ "$avail" -ge 2097152 ]; then
                echo "OK ($(($avail / 1024)) MB free)"
            else
                echo "LOW ($(($avail / 1024)) MB free)"
            fi
        fi
    done

    echo -n "APT lock free: "
    if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
        echo "OK"
    else
        echo "LOCKED"
    fi

    echo -n "DNS (archive.kali.org): "
    if getent hosts archive.kali.org >/dev/null 2>&1; then
        echo "OK"
    else
        echo "FAIL"
    fi

    echo -n "systemd-resolved active: "
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        echo "OK"
    else
        echo "inactive"
    fi

    echo -n "Required tools: "
    local missing=""
    for tool in curl wget apt dpkg; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing="$missing $tool"
        fi
    done
    if [ -z "$missing" ]; then
        echo "OK"
    else
        echo "MISSING:$missing"
    fi

    echo "=== Checks complete ==="
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --no-kernel)
            SKIP_KERNEL=true
            shift
            ;;
        --last|--status)
            show_last_run
            exit 0
            ;;
        --check|--doctor)
            run_preflight_checks
            exit 0
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        --version|-v)
            show_version
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

if $DRY_RUN; then
    info "DRY RUN MODE ENABLED - No changes will be made"
    info "DRY-RUN skips keyring refresh, apt-get update, and destructive steps"
fi

# ────────────────────────────────────────────────────────────────
# Logging (with color stripping for file)
# ────────────────────────────────────────────────────────────────
LOG_DIR="/var/log/kali-update"
LOG_FILE="$LOG_DIR/kali-update-$(date +%Y%m%d-%H%M%S).log"
APT_LOG="$LOG_FILE.apt-warnings"

mkdir -p "$LOG_DIR"
chmod 755 "$LOG_DIR"

exec > >(tee >(sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")) 2>&1

log "Running kali-update version: $VERSION"

# Keep the last N main logs and the matching apt-warnings sidecars.
# Orphan *.apt-warnings (main log already gone) are removed too.
log "Cleaning up old logs (keeping last $LOG_RETENTION)..."
while IFS= read -r oldlog; do
    [ -n "$oldlog" ] || continue
    rm -f "$oldlog" "${oldlog}.apt-warnings"
done < <(
    find "$LOG_DIR" -name 'kali-update-*.log' -type f -printf '%T@ %p\n' \
        | sort -n | head -n "-${LOG_RETENTION}" | cut -d' ' -f2-
)
for sidecar in "$LOG_DIR"/kali-update-*.log.apt-warnings; do
    [ -e "$sidecar" ] || continue
    [ -f "${sidecar%.apt-warnings}" ] || rm -f "$sidecar"
done

SCRIPT_START=$(date +%s)
if [ -f /var/run/reboot-required ]; then
    REBOOT_REQUIRED_MTIME_BEFORE=$(stat -c %Y /var/run/reboot-required 2>/dev/null || echo 0)
fi

# ────────────────────────────────────────────────────────────────
# Environment
# ────────────────────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

# ────────────────────────────────────────────────────────────────
# Pre-flight checks
# ────────────────────────────────────────────────────────────────

if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root (use sudo)."
    exit 1
fi

# Improved connectivity check (Kali archive first)
info "Checking internet connectivity..."
if ! timeout 5 bash -c "echo > /dev/tcp/archive.kali.org/443" 2>/dev/null; then
    if ! ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        error "No internet connection detected."
        exit 1
    fi
fi

for partition in "/" "/var" "/boot"; do
    if [ -d "$partition" ]; then
        avail_kb=$(df "$partition" --output=avail | tail -n 1)
        if [ "$avail_kb" -lt 2097152 ]; then
            error "Less than 2 GB free on $partition"
            exit 1
        fi
    fi
done

# Extra defensive check for /boot (common failure point for kernel updates)
if [ -d /boot ]; then
    boot_kb=$(df /boot --output=avail | tail -n 1)
    if [ "$boot_kb" -lt 51200 ]; then   # < 50 MB
        warn "Very low space on /boot (< 50 MB). Kernel updates may fail."
    fi
fi

# Check for APT lock
if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
    warn "APT is locked by another process. Waiting up to 60s..."
    for i in {1..12}; do
        if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
            break
        fi
        sleep 5
    done
    if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
        error "APT still locked after waiting. Please resolve and try again."
        exit 1
    fi
fi

if ! getent hosts archive.kali.org >/dev/null 2>&1; then
    warn "Name resolution failed for archive.kali.org."
fi

BEFORE=$(df / /var /boot --output=used 2>/dev/null | awk 'NR>1 {s+=$1} END {print s}')

# ────────────────────────────────────────────────────────────────
# Simple file lock + trap
# ────────────────────────────────────────────────────────────────
LOCKFILE="/var/run/kali-update.lock"
exec 200>"$LOCKFILE"
if ! flock -n 200; then
    error "Another instance of kali-update is already running."
    exit 1
fi
cleanup() {
    trap - INT TERM EXIT ERR
    local rc=${1:-$?}
    if [ "${AUTOREMOVE_HOLD_ACTIVE:-false}" = true ]; then
        apt-mark unhold base-files base-passwd bash coreutils util-linux ${RUNNING_KIMG_HELD:-} >/dev/null 2>&1 || true
    fi
    if [ "${KALI_MIRROR_TEMPORARY:-false}" = true ] && [ -n "${KALI_SOURCES_BACKUP:-}" ] && [ -f "$KALI_SOURCES_BACKUP" ]; then
        cp -a "$KALI_SOURCES_BACKUP" /etc/apt/sources.list 2>/dev/null || true
        rm -f "$KALI_SOURCES_BACKUP"
        KALI_MIRROR_TEMPORARY=false
    fi
    sync 2>/dev/null || true
    flock -u 200 2>/dev/null || true
    exec 200>&- 2>/dev/null || true
    rm -f "$LOCKFILE" 2>/dev/null || true
    exit "$rc"
}

trap 'cleanup $?' INT TERM EXIT

# ────────────────────────────────────────────────────────────────
# Helper for non-critical steps
# ────────────────────────────────────────────────────────────────
safe_run() {
    local desc="$1"; shift
    info "$desc"
    if ! "$@"; then
        warn "$desc failed — continuing"
    fi
}

# ────────────────────────────────────────────────────────────────
# New helper functions for --version, --last, --check
# ────────────────────────────────────────────────────────────────



# ────────────────────────────────────────────────────────────────
# Keyring (with signature verification)
# ────────────────────────────────────────────────────────────────

# Download to a temp file. curl -o on the live keyring truncates it when the
# connection resets, which is worse than keeping the previous keyring.
refresh_kali_keyring() {
    local url tmp asc_tmp fetcher=ok
    KEYRING_PATH="/usr/share/keyrings/kali-archive-keyring.gpg"
    local -a urls=(
        "https://archive.kali.org/archive-keyring.gpg"
        "https://http.kali.org/kali/archive-keyring.gpg"
        "https://kali.download/archive-keyring.gpg"
    )

    info "Refreshing Kali archive keyring..."
    tmp=$(mktemp)
    asc_tmp=$(mktemp)
    for url in "${urls[@]}"; do
        fetcher=fail
        if has_cmd curl; then
            curl -fsSL --retry 2 --retry-delay 2 "$url" -o "$tmp" && fetcher=ok
        elif has_cmd wget; then
            wget -qO "$tmp" "$url" && fetcher=ok
        else
            warn "curl/wget not available — skipping keyring refresh"
            rm -f "$tmp" "$asc_tmp"
            return 0
        fi
        if [ "$fetcher" = ok ] && [ -s "$tmp" ]; then
            info "Keyring downloaded from $url"
            install -m 0644 "$tmp" "$KEYRING_PATH"
            if has_cmd curl; then
                curl -fsSL --retry 2 --retry-delay 2 "${url}.asc" -o "$asc_tmp" 2>/dev/null || true
            elif has_cmd wget; then
                wget -qO "$asc_tmp" "${url}.asc" 2>/dev/null || true
            fi
            if [ -s "$asc_tmp" ] && has_cmd gpg; then
                if gpg --verify "$asc_tmp" "$KEYRING_PATH" >/dev/null 2>&1; then
                    info "Keyring signature verified successfully"
                else
                    warn "Keyring signature verification failed — installed keyring kept"
                fi
            elif ! has_cmd gpg; then
                warn "gpg not installed, skipping signature verification (install gnupg for better security)"
            fi
            rm -f "$tmp" "$asc_tmp"
            return 0
        fi
        warn "Keyring download failed: $url"
    done
    rm -f "$tmp" "$asc_tmp"
    warn "Failed to download keyring from every mirror — keeping the installed keyring"
    if [ ! -s "$KEYRING_PATH" ]; then
        _record_failure
    fi
    return 1
}

# apt-get update exits 0 when only some indexes fail. A Kali miss retries
# mirrors. HTTPS mirrors may be saved. An HTTP fallback is used only for this
# run, then the previous sources.list is restored. A third-party repo failure
# (Proton, for example) does not change the Kali line.
KALI_MIRROR_HTTPS=(
    "https://http.kali.org/kali"
    "https://kali.download/kali"
)
KALI_MIRROR_HTTP=(
    "http://ftp.halifax.rwth-aachen.de/kali"
    "http://mirror.math.princeton.edu/pub/kali"
)
UPGRADE_OK=true
KALI_SOURCES_BACKUP=""
KALI_MIRROR_TEMPORARY=false
STILL_UPGRADABLE=""

_kali_fetch_failed() {
    local outfile="$1"
    grep -E -q 'Failed to fetch https?://[^[:space:]]*kali[^[:space:]]*' "$outfile"
}

_current_kali_mirror() {
    awk '/^[[:space:]]*deb[[:space:]]/ && $2 ~ /\/kali$/ { print $2; exit }' /etc/apt/sources.list 2>/dev/null || true
}

_mirror_already_listed() {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

apt_get_update_with_fallback() {
    local out rc mirror backup current
    local -a order=()

    out=$(mktemp)
    if [ ! -f /etc/apt/sources.list ]; then
        rm -f "$out"
        warn "No /etc/apt/sources.list; cannot update Kali"
        _record_failure
        UPGRADE_OK=false
        return 1
    fi
    if ! grep -E -q '^[[:space:]]*deb[[:space:]]+https?://[^[:space:]]+/kali[[:space:]]' /etc/apt/sources.list; then
        rm -f "$out"
        warn "No Kali deb line in /etc/apt/sources.list"
        _record_failure
        UPGRADE_OK=false
        return 1
    fi

    backup=$(mktemp)
    cp -a /etc/apt/sources.list "$backup"
    current=$(_current_kali_mirror)

    # Official HTTPS first, unless that is already the configured mirror
    # (then try it before the other HTTPS mirror). HTTP stays last.
    if [[ "$current" == https://* ]]; then
        order+=("$current")
    fi
    for mirror in "${KALI_MIRROR_HTTPS[@]}"; do
        _mirror_already_listed "$mirror" "${order[@]+"${order[@]}"}" && continue
        order+=("$mirror")
    done
    if [ -n "$current" ]; then
        _mirror_already_listed "$current" "${order[@]+"${order[@]}"}" || order+=("$current")
    fi
    for mirror in "${KALI_MIRROR_HTTP[@]}"; do
        _mirror_already_listed "$mirror" "${order[@]+"${order[@]}"}" && continue
        order+=("$mirror")
    done

    info "Updating package lists..."
    for mirror in "${order[@]}"; do
        sed -E "s#https?://[^[:space:]]+/kali#${mirror}#g" "$backup" > /etc/apt/sources.list
        if [ "$mirror" != "$current" ]; then
            info "Trying Kali mirror $mirror"
        fi
        : >"$out"
        rc=0
        apt-get update 2>&1 | tee -a "$APT_LOG" "$out" || rc=$?
        if _kali_fetch_failed "$out"; then
            warn "Mirror $mirror did not serve the Kali index"
            continue
        fi
        if [ "$rc" -ne 0 ]; then
            warn "A non-Kali repository failed during apt-get update; keeping Kali mirror $mirror"
        fi
        if [[ "$mirror" == https://* ]]; then
            info "Kali mirror in use: $mirror (saved to /etc/apt/sources.list)"
            KALI_MIRROR_TEMPORARY=false
            rm -f "$out" "$backup"
            KALI_SOURCES_BACKUP=""
            return 0
        fi
        if [ "$mirror" = "$current" ]; then
            info "Kali mirror in use: $mirror (already configured)"
            KALI_MIRROR_TEMPORARY=false
            rm -f "$out" "$backup"
            KALI_SOURCES_BACKUP=""
            return 0
        fi
        info "Kali mirror in use for this run only: $mirror (sources.list restored when the run finishes)"
        KALI_MIRROR_TEMPORARY=true
        KALI_SOURCES_BACKUP="$backup"
        rm -f "$out"
        return 0
    done

    cp -a "$backup" /etc/apt/sources.list
    rm -f "$out" "$backup"
    KALI_SOURCES_BACKUP=""
    KALI_MIRROR_TEMPORARY=false
    warn "apt-get update had issues (see $APT_LOG)"
    _record_failure
    UPGRADE_OK=false
    return 1
}

# Permanent holds block upgrades (util-linux on hold keeps the whole 2.42
# stack "kept back"). Drop holds this script used to leave behind. A short
# hold around autoremove is applied and released later.
release_legacy_holds() {
    local pkg
    info "Releasing holds that block upgrades..."
    apt-mark unhold base-files base-passwd bash coreutils util-linux 2>/dev/null || true
    while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
        apt-mark unhold "$pkg" 2>/dev/null || true
        info "Unheld $pkg"
    done < <(apt-mark showhold 2>/dev/null | grep -E '^(linux-image|linux-binary)-' || true)
}

# ────────────────────────────────────────────────────────────────
# Core update
# ────────────────────────────────────────────────────────────────

if $DRY_RUN; then
    info "DRY-RUN: Would refresh Kali archive keyring (with mirror retry)"
    info "DRY-RUN: Would release legacy apt holds (base-files, bash, util-linux, kernels)"
    info "DRY-RUN: Would run dpkg --configure -a"
    info "DRY-RUN: Would run apt-get install -f"
    info "DRY-RUN: Would run apt-get update, preferring an HTTPS Kali mirror; HTTP mirrors are not saved"
else
    refresh_kali_keyring || true
    release_legacy_holds

    info "Configuring any interrupted package installations..."
    dpkg --configure -a || warn "dpkg --configure -a had issues"

    info "Fixing broken dependencies..."
    apt-get install -f -y || warn "apt install -f had issues"

    apt_get_update_with_fallback || true
fi

info "Checking package cache integrity (apt-get check)..."
apt-get check || warn "Package cache check reported issues (see $APT_LOG)"

if $DRY_RUN; then
    info "DRY-RUN: Would run apt-get upgrade"
    info "DRY-RUN: Would run apt-get full-upgrade"
    apt list --upgradable 2>/dev/null | sed -n '1,40p' || true
else
    info "Upgrading packages..."
    if ! apt-get upgrade -y 2>&1 | tee -a "$APT_LOG"; then
        warn "apt upgrade had issues (see $APT_LOG)"
        _record_failure
        UPGRADE_OK=false
    fi

    info "Listing upgradable packages after initial upgrade:"
    apt list --upgradable 2>/dev/null || true

    info "Performing full system upgrade..."
    if ! apt-get full-upgrade -y 2>&1 | tee -a "$APT_LOG"; then
        warn "full-upgrade had issues (see $APT_LOG)"
        _record_failure
        UPGRADE_OK=false
    fi

    STILL_UPGRADABLE=$(apt list --upgradable 2>/dev/null | awk -F/ 'NR>1 && $1 != "" { print $1 }' || true)
fi

# ────────────────────────────────────────────────────────────────
# Complete cleanup
# ────────────────────────────────────────────────────────────────

# Hold only for autoremove, then release. A lasting hold prevents the next
# upgrade of base-files, bash, and util-linux (and everything tied to them).
AUTOREMOVE_HOLDS=(base-files base-passwd bash coreutils util-linux)
release_autoremove_holds() {
    apt-mark unhold "${AUTOREMOVE_HOLDS[@]}" 2>/dev/null || true
}

if $DRY_RUN; then
    info "DRY-RUN: Would hold critical packages only during autoremove, then release them"
    info "DRY-RUN: Would run autoremove, clean, purge configs, kernel removal, etc."
else
    running_kimg=$(find_running_kernel_pkg "$(uname -r)" || true)
    info "Holding critical packages during autoremove..."
    AUTOREMOVE_HOLD_ACTIVE=true
    if [ -n "$running_kimg" ]; then
        RUNNING_KIMG_HELD="$running_kimg"
        apt-mark hold "${AUTOREMOVE_HOLDS[@]}" "$running_kimg" 2>/dev/null || true
    else
        apt-mark hold "${AUTOREMOVE_HOLDS[@]}" 2>/dev/null || true
    fi

    info "Removing unnecessary packages (autoremove --purge)..."
    apt-get --purge autoremove -y 2>&1 | tee -a "$APT_LOG" || warn "autoremove had issues"

    release_autoremove_holds
    if [ -n "${running_kimg:-}" ]; then
        apt-mark unhold "$running_kimg" 2>/dev/null || true
    fi
    AUTOREMOVE_HOLD_ACTIVE=false
    info "Critical-package holds released"

    info "Cleaning obsolete package cache (autoclean)..."
    apt-get autoclean
    if [ "$UPGRADE_OK" = true ]; then
        info "Cleaning package cache..."
        apt-get clean
    else
        warn "Skipping apt clean because the upgrade did not finish (keeping downloaded archives for the next run)"
    fi

    info "Purging residual configuration files..."
    apt-get purge '~c' -y 2>&1 | tee -a "$APT_LOG" || warn "Purging residual configs had issues"
fi

if $SKIP_KERNEL; then
    info "Skipping old kernel removal (--no-kernel)."
else
    remove_old_kernels
fi

if $KERNELS_REMOVED; then
    info "Old kernels were removed or scheduled. Recovery: boot GRUB and select a previous kernel."
fi

if $KERNELS_REMOVED && has_cmd update-grub && ! $DRY_RUN; then
    safe_run "Updating GRUB bootloader" update-grub
fi

# Flatpak cleanup
if command -v flatpak >/dev/null 2>&1; then
    if $DRY_RUN; then
        info "DRY-RUN: Would update Flatpaks and remove unused"
    else
        safe_run "Updating Flatpaks" flatpak update -y
        safe_run "Removing unused Flatpaks" flatpak uninstall --unused -y
    fi
fi

# Snap cleanup (including old revisions)
if command -v snap >/dev/null 2>&1; then
    if $DRY_RUN; then
        info "DRY-RUN: Would refresh Snaps and remove old revisions"
    else
        safe_run "Refreshing Snaps" snap refresh
        snap list --all 2>/dev/null | grep "disabled" | awk '{print $1, $3}' | while read -r snapname revision; do
            snap remove "$snapname" --revision="$revision" 2>/dev/null || true
        done
    fi
fi

# Firmware updates
if command -v fwupdmgr >/dev/null 2>&1; then
    if $DRY_RUN; then
        info "DRY-RUN: Would update firmware"
    else
        safe_run "Refreshing firmware metadata" fwupdmgr refresh --force
        safe_run "Applying firmware updates" fwupdmgr update -y || true
    fi
fi

if _is_truthy "$CLEAN_DEV_CACHES"; then
    clean_dev_caches
else
    info "Skipping pip/go-build/uv cache cleanup (CLEAN_DEV_CACHES=$CLEAN_DEV_CACHES)"
fi

# Clean old journal logs (keep last 30 days)
if command -v journalctl >/dev/null 2>&1; then
    if $DRY_RUN; then
        info "DRY-RUN: Would vacuum journal logs"
    else
        safe_run "Vacuuming journal logs (last 30 days)" journalctl --vacuum-time=30d
    fi
fi

# Clean partial apt lists
if ! $DRY_RUN; then
    info "Cleaning partial package lists..."
    rm -rf /var/lib/apt/lists/partial/*

    if command -v updatedb >/dev/null 2>&1; then
        safe_run "Updating locate database" updatedb
    fi

    if command -v mandb >/dev/null 2>&1; then
        safe_run "Rebuilding man page database" mandb -q
    fi
else
    info "DRY-RUN: Would perform final cleanups"
fi


# ────────────────────────────────────────────────────────────────
# Final status & summary
# ────────────────────────────────────────────────────────────────

AFTER=$(df / /var /boot --output=used 2>/dev/null | awk 'NR>1 {s+=$1} END {print s}')
FREED_KB=$(( BEFORE - AFTER ))
FREED_MB=$(awk "BEGIN {printf \"%.2f\", $FREED_KB / 1024 }")

REBOOT_DURING_RUN=false
if [ -f /var/run/reboot-required ]; then
    reboot_mtime=$(stat -c %Y /var/run/reboot-required 2>/dev/null || echo 0)
    if [ "$reboot_mtime" -gt "$REBOOT_REQUIRED_MTIME_BEFORE" ] \
        && [ "$reboot_mtime" -ge "$SCRIPT_START" ]; then
        REBOOT_DURING_RUN=true
    fi
fi

if [ "$REBOOT_DURING_RUN" = true ]; then
    warn "Reboot is required to complete some updates."
    warn "Run: sudo reboot"
else
    success "No reboot required from this run."


fi

# Record last run (AFTER all variables calculated in summary)
# ────────────────────────────────────────────────────────────────

LAST_RUN_DIR="/var/lib/kali-update"
LAST_RUN_FILE="$LAST_RUN_DIR/last-run"

if ! $DRY_RUN; then
    mkdir -p "$LAST_RUN_DIR"
    RUN_STATUS=success
    [ "$EXIT_CODE" -ne 0 ] && RUN_STATUS=failure
    cat > "$LAST_RUN_FILE" << LAST
VERSION=$VERSION
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
STATUS=$RUN_STATUS
FAILURES=$EXIT_CODE
DISK_FREED_MB=$FREED_MB
REBOOT_REQUIRED=$([ "$REBOOT_DURING_RUN" = true ] && echo "yes" || echo "no")
LOG_FILE=$LOG_FILE
LAST
    info "Last run record written to $LAST_RUN_FILE"
else
    info "DRY-RUN: Would write last-run record"
fi


# ────────────────────────────────────────────────────────────────

# Optional: needrestart
if command -v needrestart >/dev/null 2>&1 && ! $DRY_RUN; then
    info "Checking services that need restart..."
    needrestart -r a -l 2>/dev/null || true
elif $DRY_RUN; then
    info "DRY-RUN: Would check for services needing restart"
fi

# Desktop notification
if command -v notify-send >/dev/null 2>&1 && [ -n "${DISPLAY:-}" ]; then
    MSG="Kali update completed. Freed ${FREED_MB} MB."
    if [ "$REBOOT_DURING_RUN" = true ]; then
        MSG="$MSG Reboot recommended."
    fi
    notify-send "Kali Update" "$MSG" 2>/dev/null || true
fi

if [ "${KALI_MIRROR_TEMPORARY:-false}" = true ] && [ -n "${KALI_SOURCES_BACKUP:-}" ] && [ -f "$KALI_SOURCES_BACKUP" ]; then
    info "Restoring the previous Kali mirror in /etc/apt/sources.list"
    cp -a "$KALI_SOURCES_BACKUP" /etc/apt/sources.list
    rm -f "$KALI_SOURCES_BACKUP"
    KALI_SOURCES_BACKUP=""
    KALI_MIRROR_TEMPORARY=false
fi

log "=== Update Summary ==="
log "Disk space freed (/, /var, /boot): ${FREED_MB} MB"
log "Failures recorded: $EXIT_CODE"
if [ -n "${STILL_UPGRADABLE:-}" ]; then
    log "Still upgradable (apt kept these back):"
    while IFS= read -r pkg; do
        [ -n "$pkg" ] && log "  $pkg"
    done <<< "$STILL_UPGRADABLE"
else
    log "Still upgradable: none"
fi
log "Full log saved to: $LOG_FILE"
log "APT warnings logged to: $APT_LOG"

if [ "$EXIT_CODE" -eq 0 ]; then
    success "Kali update and cleanup completed successfully!"
    exit 0
else
    warn "Kali update finished with $EXIT_CODE failure(s)."
    exit 1
fi
