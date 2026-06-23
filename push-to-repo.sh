#!/usr/bin/env bash
# Commit v5.13 changes and push to origin/main.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

VERSION=$(cat VERSION 2>/dev/null || echo "unknown")
MSG="v${VERSION}: fix kernel logic, dry-run, and review findings"

echo "=== git status (before) ==="
git status --short

git add kali-update.sh CHANGELOG.md README.md VERSION verify-kali-update.sh push-to-repo.sh 2>/dev/null || true
git add -u

if git diff --cached --quiet; then
    echo "Nothing to commit — checking if push is needed..."
else
    echo "=== committing ==="
    git commit -m "$MSG"
fi

echo "=== pushing origin main ==="
git push origin main

echo "=== done ==="
git status
git log -1 --oneline