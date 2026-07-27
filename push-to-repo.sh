#!/usr/bin/env bash
# Commit v5.13 changes and push to origin/main.
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