#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${RUNNER_REPO_DIR:-/home/hhk/Projects/vpn}"
REMOTE="${RUNNER_REMOTE:-origin}"
BRANCH="${RUNNER_BRANCH:-main}"

if [ ! -d "$REPO_DIR/.git" ]; then
  echo "Repository not found at $REPO_DIR" >&2
  exit 1
fi

git config --global --add safe.directory "$REPO_DIR" || true
git -C "$REPO_DIR" fetch --prune "$REMOTE" "$BRANCH"
git -C "$REPO_DIR" checkout "$BRANCH"
git -C "$REPO_DIR" reset --hard "$REMOTE/$BRANCH"
git -C "$REPO_DIR" clean -fd

echo "Pulled $REMOTE/$BRANCH into $REPO_DIR"
git -C "$REPO_DIR" rev-parse --short HEAD
