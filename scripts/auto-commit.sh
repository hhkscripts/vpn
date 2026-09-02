#!/usr/bin/env bash
# Commit and push real repository content changes; no-op safely when unchanged.
set -euo pipefail

REMOTE="${AUTO_COMMIT_REMOTE:-origin}"
PUSH_ENABLED="${AUTO_COMMIT_PUSH:-1}"
MESSAGE="${1:-chore: auto-commit local changes}"

if [ -z "$MESSAGE" ]; then
  echo "Commit message must not be empty." >&2
  exit 2
fi

REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "Not inside a Git repository." >&2
  exit 2
}
cd "$REPO_DIR"

BRANCH="${AUTO_COMMIT_BRANCH:-$(git branch --show-current)}"
if [ -z "$BRANCH" ]; then
  echo "Cannot auto-commit from a detached HEAD." >&2
  exit 2
fi
if [ "$(git branch --show-current)" != "$BRANCH" ]; then
  echo "Current branch does not match target branch: $BRANCH" >&2
  exit 2
fi

GIT_DIR="$(git rev-parse --git-dir)"
exec 9>"$GIT_DIR/auto-commit.lock"
if ! flock -n 9; then
  echo "Another auto-commit process is already running." >&2
  exit 3
fi

git add -A
if git diff --cached --quiet; then
  echo "No content changes to commit. Files may have been rewritten with identical content."
  exit 0
fi

git commit -m "$MESSAGE"
COMMIT_SHA="$(git rev-parse --short HEAD)"

case "$PUSH_ENABLED" in
  0|false|FALSE|no|NO)
    echo "Committed $COMMIT_SHA locally; push disabled."
    exit 0
    ;;
esac

git pull --rebase "$REMOTE" "$BRANCH"
git push "$REMOTE" "HEAD:$BRANCH"
echo "Committed and pushed $COMMIT_SHA to $REMOTE/$BRANCH."
