#!/usr/bin/env bash
# Kali Linux - Complete Update & Cleanup Script
# Full system update + thorough cleanup for Kali Rolling
# Usage: sudo ./kali-update.sh
# Recommended: run weekly
# Config: LOG_RETENTION=3 (env var to control how many logs to keep)

set -euo pipefail

# ────────────────────────────────────────────────────────────────
# Colors
# ────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ────────────────────────────────────────────────────────────────
# Config
# ────────────────────────────────────────────────────────────────
LOG_RETENTION=${LOG_RETENTION:-3}

# ────────────────────────────────────────────────────────────────
# Logging
# ────────────────────────────────────────────────────────────────
LOG_DIR="/var/log/kali-update"
LOG_FILE="$LOG_DIR/kali-update-$(date +%Y%m%d-%H%M%S).log"
APT_LOG="$LOG_FILE.apt-warnings"

mkdir -p "$LOG_DIR"
chmod 755 "$LOG_DIR"

# Redirect all output
exec > >(tee -a "$LOG_FILE") 2>&1

log()      { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
info()     { echo -e "${BLUE}[INFO]${NC} $1"; }
success()  { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warn()     { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error()    { echo -e "${RED}[ERROR]${NC} $1"; }

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

# Check disk space on critical partitions
for partition in "/" "/var" "/boot"; do
    if [ -d "$partition" ]; then
        avail_kb=$(df "$partition" --output=avail | tail -n 1)
        if [ "$avail_kb" -lt 2097152 ]; then
            error "Less than 2 GB free on $partition"
            exit 1
        fi
    fi
done

# Check for APT lock
if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 2>/dev/null; then
    warn "APT is locked by another process. Waiting up to 60s..."
    for i in {1..12}; do
        if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 2>/dev/null; then
            break
        fi
        sleep 5
    done
    if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 2>/dev/null; then
        error "APT still locked after waiting. Please resolve and try again."
        exit 1
    fi
fi

# Check systemd-resolved
if ! systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    warn "systemd-resolved is not active. DNS resolution may be affected."
fi

# Record disk before
BEFORE=$(df / --output=used | tail -1)

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
# Refresh Kali keyring (with signature verification)
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

info "Upgrading packages..."
apt upgrade -y 2>&1 | tee -a "$APT_LOG" || warn "apt upgrade had issues"

info "Listing upgradable packages after initial upgrade:"
apt list --upgradable 2>/dev/null || true

info "Performing full system upgrade..."
apt full-upgrade -y 2>&1 | tee -a "$APT_LOG" || warn "full-upgrade had issues"

# ────────────────────────────────────────────────────────────────
# Complete cleanup
# ────────────────────────────────────────────────────────────────

# Protect critical packages
info "Holding critical packages to prevent accidental removal..."
apt-mark hold base-files base-passwd bash coreutils util-linux linux-image-$(uname -r) 2>/dev/null || true

info "Removing unnecessary packages (autoremove --purge)..."
apt --purge autoremove -y 2>&1 | tee -a "$APT_LOG" || warn "autoremove had issues"

info "Cleaning package cache (autoclean + clean)..."
apt autoclean
apt clean

# Purge residual configuration files (very common cleanup)
info "Purging residual configuration files..."
apt purge '~c' -y 2>&1 | tee -a "$APT_LOG" || warn "Purging residual configs had issues"

# Remove old kernels (keep current + previous one)
info "Removing old kernels (keeping current + previous)..."
CURRENT=$(uname -r)
KERNELS=$(dpkg -l 'linux-image-*' 2>/dev/null | awk '/^ii/ {print $2}' | grep -v "$CURRENT" | sort -V | head -n -1 || true)
if [ -n "$KERNELS" ]; then
    echo "$KERNELS" | xargs apt purge -y 2>&1 | tee -a "$APT_LOG" || warn "Old kernel removal had issues"
    # Also remove matching headers and modules
    for k in $KERNELS; do
        echo "$k" | sed 's/linux-image/linux-headers/' | xargs apt purge -y 2>/dev/null || true
        echo "$k" | sed 's/linux-image/linux-modules/'  | xargs apt purge -y 2>/dev/null || true
    done
else
    info "No old kernels to remove."
fi

# Update GRUB if kernels were removed
if [ -n "$KERNELS" ] && command -v update-grub >/dev/null 2>&1; then
    safe_run "Updating GRUB bootloader" update-grub
fi

# Flatpak cleanup
if command -v flatpak >/dev/null 2>&1; then
    safe_run "Updating Flatpaks" flatpak update -y
    safe_run "Removing unused Flatpaks" flatpak uninstall --unused -y
fi

# Snap cleanup (including old revisions)
if command -v snap >/dev/null 2>&1; then
    safe_run "Refreshing Snaps" snap refresh
    # Remove disabled/old revisions with better error handling
    snap list --all 2>/dev/null | grep "disabled" | awk '{print $1, $3}' | while read -r snapname revision; do
        snap remove "$snapname" --revision="$revision" 2>/dev/null || true
    done
fi

# Firmware updates
if command -v fwupdmgr >/dev/null 2>&1; then
    safe_run "Refreshing firmware metadata" fwupdmgr refresh --force
    safe_run "Applying firmware updates" fwupdmgr update -y || true
fi

# Clean old journal logs (keep last 30 days)
if command -v journalctl >/dev/null 2>&1; then
    safe_run "Vacuuming journal logs (last 30 days)" journalctl --vacuum-time=30d
fi

# Clean partial apt lists
info "Cleaning partial package lists..."
rm -rf /var/lib/apt/lists/partial/*

# Update locate database if installed
if command -v updatedb >/dev/null 2>&1; then
    safe_run "Updating locate database" updatedb
fi

# Rebuild man page database
if command -v mandb >/dev/null 2>&1; then
    safe_run "Rebuilding man page database" mandb -q
fi

# ────────────────────────────────────────────────────────────────
# Final status & summary
# ────────────────────────────────────────────────────────────────

AFTER=$(df / --output=used | tail -1)
FREED_MB=$(echo "scale=2; ($BEFORE - $AFTER) / 1024" | bc 2>/dev/null || echo "N/A")

# Validate if upgrades caused reboot-required during this run
REBOOT_DURING_RUN=false
if [ -f /var/run/reboot-required ]; then
    if [ $(stat -c %Y /var/run/reboot-required 2>/dev/null || echo 0) -gt $SCRIPT_START ]; then
        REBOOT_DURING_RUN=true
    fi
fi

if [ "$REBOOT_DURING_RUN" = true ]; then
    warn "Reboot is required to complete some updates (kernel, libc, etc.)."
    warn "Run: sudo reboot"
else
    success "No reboot required from this run."
fi

success "Kali update and cleanup completed successfully!"
log "=== Update Summary ==="
log "Disk space freed: ${FREED_MB} MB"
log "Full log saved to: $LOG_FILE"
log "APT warnings logged to: $APT_LOG"
exit 0
