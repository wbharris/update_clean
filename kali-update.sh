#!/usr/bin/env bash
# Kali Linux - Complete Update & Cleanup Script
# Full system update + thorough cleanup for Kali Rolling
# Usage: sudo ./kali-update.sh [--dry-run] [--no-kernel] [--help] [--version]
# Recommended: run weekly

set -euo pipefail

# ────────────────────────────────────────────────────────────────
# Defaults & Config
# ────────────────────────────────────────────────────────────────
DRY_RUN=false
SKIP_KERNEL=false
LOG_RETENTION=${LOG_RETENTION:-3}
VERSION="5.8"

# Load config file if present
for conf in /etc/kali-update.conf "$HOME/.config/kali-update.conf" "$HOME/.kali-update.conf"; do
    [ -f "$conf" ] && source "$conf"
done

# ────────────────────────────────────────────────────────────────
# Colors (define early)
# ────────────────────────────────────────────────────────────────
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

# ────────────────────────────────────────────────────────────────
# Logging
# ────────────────────────────────────────────────────────────────
LOG_DIR="/var/log/kali-update"
LOG_FILE="$LOG_DIR/kali-update-$(date +%Y%m%d-%H%M%S).log"
APT_LOG="$LOG_FILE.apt-warnings"

mkdir -p "$LOG_DIR"
chmod 755 "$LOG_DIR"

# Redirect all output (after functions are defined)
exec > >(tee -a "$LOG_FILE") 2>&1

log "Running kali-update version: $VERSION"

# Keep only the last N log files
log "Cleaning up old logs (keeping last $LOG_RETENTION)..."
find "$LOG_DIR" -name "kali-update-*.log" -type f -printf '%T@ %p\n' \
    | sort -n | head -n "-$LOG_RETENTION" | cut -d' ' -f2- | xargs -r rm -f

# Record start time for upgrade validation
SCRIPT_START=$(date +%s)

# ────────────────────────────────────────────────────────────────
# Environment
# ────────────────────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

# ────────────────────────────────────────────────────────────────
# CLI Parsing
# ────────────────────────────────────────────────────────────────
usage() {
    cat << USAGE
Usage: sudo $0 [options]

Options:
  --dry-run       Simulate actions without making changes
  --no-kernel     Skip old kernel removal
  --help, -h      Show this help
  --version, -v   Show version

Environment:
  LOG_RETENTION   Number of logs to keep (default: 3)
USAGE
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
        --help|-h)
            usage
            exit 0
            ;;
        --version|-v)
            echo "kali-update $VERSION"
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
fi

# ────────────────────────────────────────────────────────────────
# Pre-flight checks
# ────────────────────────────────────────────────────────────────

if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root (use sudo)."
    exit 1
fi

info "Checking internet connectivity..."
if ! ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
    error "No internet connection detected."
    exit 1
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

# Check for APT lock (fixed duplicate redirect)
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

if ! systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    warn "systemd-resolved is not active. DNS resolution may be affected."
fi

BEFORE=$(df / --output=used | tail -1)

# ────────────────────────────────────────────────────────────────
# Simple file lock + trap
# ────────────────────────────────────────────────────────────────
LOCKFILE="/var/run/kali-update.lock"
exec 200>"$LOCKFILE"
if ! flock -n 200; then
    error "Another instance of kali-update is already running."
    exit 1
fi
trap 'rm -f "$LOCKFILE"' EXIT

# ────────────────────────────────────────────────────────────────
# Helper
# ────────────────────────────────────────────────────────────────
safe_run() {
    local desc="$1"; shift
    info "$desc"
    if ! "$@"; then
        warn "$desc failed — continuing"
    fi
}

# ────────────────────────────────────────────────────────────────
# Keyring (with signature verification)
# ────────────────────────────────────────────────────────────────

info "Refreshing Kali archive keyring..."
KEYRING_URL="https://archive.kali.org/archive-keyring.gpg"
KEYRING_PATH="/usr/share/keyrings/kali-archive-keyring.gpg"
KEYRING_ASC_URL="${KEYRING_URL}.asc"
KEYRING_ASC_PATH="${KEYRING_PATH}.asc"

if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$KEYRING_URL" -o "$KEYRING_PATH" || warn "Failed to download keyring"
    curl -fsSL "$KEYRING_ASC_URL" -o "$KEYRING_ASC_PATH" 2>/dev/null || true
elif command -v wget >/dev/null 2>&1; then
    wget -qO "$KEYRING_PATH" "$KEYRING_URL" || warn "Failed to download keyring"
    wget -qO "$KEYRING_ASC_PATH" "$KEYRING_ASC_URL" 2>/dev/null || true
else
    warn "curl/wget not available — skipping keyring refresh"
fi

if [ -f "$KEYRING_ASC_PATH" ] && [ -f "$KEYRING_PATH" ]; then
    if command -v gpg >/dev/null 2>&1; then
        if gpg --verify "$KEYRING_ASC_PATH" "$KEYRING_PATH" >/dev/null 2>&1; then
            info "Keyring signature verified successfully"
        else
            warn "Keyring signature verification failed — using anyway (may cause issues)"
        fi
    else
        warn "gpg not installed, skipping signature verification (install gnupg for better security)"
    fi
    rm -f "$KEYRING_ASC_PATH"
fi

# ────────────────────────────────────────────────────────────────
# Core update
# ────────────────────────────────────────────────────────────────

info "Configuring any interrupted package installations..."
dpkg --configure -a || warn "dpkg --configure -a had issues"

info "Fixing broken dependencies..."
apt install -f -y || warn "apt install -f had issues"

info "Updating package lists..."
apt update

info "Checking package cache integrity (apt-get check)..."
apt-get check || warn "Package cache check reported issues"

APT_OPTS="-y"
if $DRY_RUN; then
    APT_OPTS="-s"
    info "DRY-RUN: Using simulation mode for APT commands"
fi

info "Upgrading packages..."
apt upgrade $APT_OPTS 2>&1 | tee -a "$APT_LOG" || warn "apt upgrade had issues"

info "Listing upgradable packages after initial upgrade:"
apt list --upgradable 2>/dev/null || true

info "Performing full system upgrade..."
apt full-upgrade $APT_OPTS 2>&1 | tee -a "$APT_LOG" || warn "full-upgrade had issues"

# ────────────────────────────────────────────────────────────────
# Complete cleanup
# ────────────────────────────────────────────────────────────────

info "Holding critical packages to prevent accidental removal..."
apt-mark hold base-files base-passwd bash coreutils util-linux linux-image-$(uname -r) 2>/dev/null || true

if $DRY_RUN; then
    info "DRY-RUN: Would run autoremove, clean, purge configs, kernel removal, etc."
else
    info "Removing unnecessary packages (autoremove --purge)..."
    apt --purge autoremove -y 2>&1 | tee -a "$APT_LOG" || warn "autoremove had issues"

    info "Cleaning package cache (autoclean + clean)..."
    apt autoclean
    apt clean

    info "Purging residual configuration files..."
    apt purge '~c' -y 2>&1 | tee -a "$APT_LOG" || warn "Purging residual configs had issues"
fi

# Remove old kernels (keep current + previous one) - fixed logic
info "Removing old kernels (keeping current + previous)..."
CURRENT=$(uname -r)
KERNELS=$(dpkg -l 'linux-image-*' 2>/dev/null | awk '/^ii/ {print $2}' | grep -v "$CURRENT" | sort -V | tail -n +2 || true)
if [ -n "$KERNELS" ]; then
    echo "$KERNELS" | while read -r k; do
        apt purge -y "$k" 2>&1 | tee -a "$APT_LOG" || warn "Failed to purge $k"
        # Also remove matching headers and modules
        echo "$k" | sed 's/linux-image/linux-headers/' | xargs apt purge -y 2>/dev/null || true
        echo "$k" | sed 's/linux-image/linux-modules/'  | xargs apt purge -y 2>/dev/null || true
    done
else
    info "No old kernels to remove."
fi

if [ -n "$KERNELS" ] && command -v update-grub >/dev/null 2>&1 && ! $DRY_RUN; then
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

# Snap cleanup
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

# Clean old journal logs
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
# Record last run
# ────────────────────────────────────────────────────────────────

LAST_RUN_DIR="/var/lib/kali-update"
LAST_RUN_FILE="$LAST_RUN_DIR/last-run"

if ! $DRY_RUN; then
    mkdir -p "$LAST_RUN_DIR"
    cat > "$LAST_RUN_FILE" << LAST
VERSION=$VERSION
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
STATUS=success
DISK_FREED_MB=$FREED_MB
REBOOT_REQUIRED=$([ "$REBOOT_DURING_RUN" = true ] && echo "yes" || echo "no")
LOG_FILE=$LOG_FILE
LAST
    info "Last run record written to $LAST_RUN_FILE"
else
    info "DRY-RUN: Would write last-run record"
fi

# ────────────────────────────────────────────────────────────────
# Final status & summary
# ────────────────────────────────────────────────────────────────

AFTER=$(df / --output=used | tail -1)
FREED_KB=$(( BEFORE - AFTER ))
FREED_MB=$(awk "BEGIN {printf \"%.2f\", $FREED_KB / 1024 }")

REBOOT_DURING_RUN=false
if [ -f /var/run/reboot-required ]; then
    if [ $(stat -c %Y /var/run/reboot-required 2>/dev/null || echo 0) -gt $SCRIPT_START ]; then
        REBOOT_DURING_RUN=true
    fi
fi

if [ "$REBOOT_DURING_RUN" = true ]; then
    warn "Reboot is required to complete some updates."
    warn "Run: sudo reboot"
else
    success "No reboot required from this run."
fi

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

success "Kali update and cleanup completed successfully!"
log "=== Update Summary ==="
log "Disk space freed: ${FREED_MB} MB"
log "Full log saved to: $LOG_FILE"
log "APT warnings logged to: $APT_LOG"
exit 0
