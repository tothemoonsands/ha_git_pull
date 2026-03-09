#!/usr/bin/env bash
set -euo pipefail

# Creates a clean, linear branch that keeps only meaningful code commits
# and drops noisy merge/branding churn from this fork's history.

TARGET_BRANCH="${1:-codex/public-history}"
BASE_COMMIT="23887b3"

IMPORTANT_COMMITS=(
  ddd8758
  3892cc3
  540dcd1
  2049015
  273a030
  611a23f
  c2e8bb9
  481e8a9
  a5f37b6
  a7c6bde
  9ff649c
)

if ! git rev-parse --verify "$BASE_COMMIT^{commit}" >/dev/null 2>&1; then
  echo "Base commit $BASE_COMMIT was not found." >&2
  exit 1
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Working tree is not clean. Commit/stash changes before running this script." >&2
  exit 1
fi

current_branch="$(git branch --show-current)"

echo "Creating ${TARGET_BRANCH} from ${BASE_COMMIT}"
git switch --create "$TARGET_BRANCH" "$BASE_COMMIT"

for commit in "${IMPORTANT_COMMITS[@]}"; do
  echo "Cherry-picking $commit"
  git cherry-pick "$commit"
done

echo
echo "Created clean branch: ${TARGET_BRANCH}"
echo "Started from: ${BASE_COMMIT}"
echo "Original branch was: ${current_branch}"
echo
echo "Next steps:"
echo "  1) Verify: git log --oneline --decorate --graph -n 30"
echo "  2) Validate addon behavior in Home Assistant"
echo "  3) Push branch (new public repo recommended):"
echo "     git push -u <new-origin> ${TARGET_BRANCH}:master"
