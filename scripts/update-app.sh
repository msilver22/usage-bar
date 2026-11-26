#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -n "$(git status --porcelain)" ]]; then
    echo "Commit or stash local changes in $PWD before updating." >&2
    exit 1
fi

git fetch origin main

if ! git pull --ff-only origin main 2>/dev/null; then
    if ! git pull --rebase origin main; then
        git rebase --abort >/dev/null 2>&1 || true
        echo "Rebase onto origin/main failed. Resolve conflicts manually in $PWD." >&2
        exit 1
    fi
fi

bash scripts/build-app.sh
