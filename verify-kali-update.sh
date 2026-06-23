#!/usr/bin/env bash
# Verify kali-update.sh after changes (syntax, version, preflight, dry-run).
# Optional: commit and push v5.13+ changes.
#
# Usage:
#   ./verify-kali-update.sh              # checks only
#   ./verify-kali-update.sh --commit       # checks + git commit
#   ./verify-kali-update.sh --commit --push

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MAIN_SCRIPT="$SCRIPT_DIR/kali-update.sh"
VERSION_FILE="$SCRIPT_DIR/VERSION"

DO_COMMIT=false
DO_PUSH=false

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail()    { echo -e "${RED}[FAIL]${NC} $1" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Usage: ./verify-kali-update.sh [options]

Runs local verification for kali-update.sh:
  - bash -n syntax check
  - --version
  - --check (sudo if not root)
  - --dry-run (sudo if not root)

Options:
  --commit    Stage and commit kali-update.sh, CHANGELOG.md, README.md, VERSION
  --push      Push to origin after commit (implies --commit)
  --help, -h  Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --commit) DO_COMMIT=true; shift ;;
        --push)   DO_COMMIT=true; DO_PUSH=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) fail "Unknown option: $1 (try --help)" ;;
    esac
done

[ -f "$MAIN_SCRIPT" ] || fail "Missing $MAIN_SCRIPT"
[ -x "$MAIN_SCRIPT" ] || chmod +x "$MAIN_SCRIPT"

run_as_root() {
    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        fail "Root required for: $* (re-run as root or install sudo)"
    fi
}

info "=== kali-update verification ==="
info "Script: $MAIN_SCRIPT"

info "1/4 Syntax check (bash -n)..."
bash -n "$MAIN_SCRIPT"
success "Syntax OK"

info "2/4 Version..."
"$MAIN_SCRIPT" --version
success "Version OK"

info "3/4 Pre-flight checks (--check)..."
run_as_root "$MAIN_SCRIPT" --check
success "Pre-flight checks OK"

info "4/4 Dry-run (--dry-run)..."
run_as_root "$MAIN_SCRIPT" --dry-run
success "Dry-run OK"

success "All verification steps passed."

if $DO_COMMIT; then
    info "=== Git commit ==="
    [ -d "$SCRIPT_DIR/.git" ] || fail "Not a git repo: $SCRIPT_DIR"

    cd "$SCRIPT_DIR"
    VERSION=$(cat "$VERSION_FILE" 2>/dev/null || echo "unknown")
    FILES=(kali-update.sh CHANGELOG.md README.md VERSION)

    for f in "${FILES[@]}"; do
        [ -f "$f" ] || warn "Missing $f (skipping from commit)"
    done

    git add "${FILES[@]}" 2>/dev/null || true
    if git diff --cached --quiet; then
        warn "Nothing staged to commit."
    else
        git commit -m "v${VERSION}: fix kernel logic, dry-run, and review findings"
        success "Committed v${VERSION}"
    fi

    if $DO_PUSH; then
        info "Pushing to origin..."
        git push
        success "Pushed to origin"
    fi
fi

info "Done."