#!/usr/bin/env bash
# Rebase develop-patched on the latest upstream develop branch.
#
# Usage: ./scripts/sync-upstream.sh
#
# Requires:
#   - 'upstream' remote pointing at the canonical Baseflow/flutter_cache_manager repo
#   - working tree clean
set -euo pipefail

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree is not clean. Commit or stash first." >&2
  exit 1
fi

git fetch upstream
git checkout develop-patched
git rebase upstream/develop

echo
echo "develop-patched is now up to date with upstream/develop."
echo "Push with: git push --force-with-lease origin develop-patched"
