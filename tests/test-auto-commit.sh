#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$PROJECT_ROOT/scripts/auto-commit.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

setup_repo() {
  local name="$1"
  local bare="$TMP_DIR/$name.git"
  local work="$TMP_DIR/$name"

  git init --bare --initial-branch=main "$bare" >/dev/null
  git clone "$bare" "$work" >/dev/null 2>&1
  git -C "$work" config user.name "Auto Commit Test"
  git -C "$work" config user.email "auto-commit@example.invalid"
  printf 'initial\n' > "$work/tracked.txt"
  git -C "$work" add tracked.txt
  git -C "$work" commit -m "initial" >/dev/null
  git -C "$work" push -u origin main >/dev/null 2>&1
  printf '%s\n' "$work"
}

# Rewriting a file with identical content must be a successful no-op.
repo="$(setup_repo no-change)"
before="$(git -C "$repo" rev-parse HEAD)"
printf 'initial\n' > "$repo/tracked.txt"
output="$(cd "$repo" && "$HELPER" "test: should not commit")"
after="$(git -C "$repo" rev-parse HEAD)"
[[ "$before" == "$after" ]] || fail "identical content created a commit"
[[ "$output" == *"No content changes to commit"* ]] || fail "missing no-change message"
[[ -z "$(git -C "$repo" status --porcelain)" ]] || fail "no-change repository is dirty"
echo "PASS: identical rewrite is a no-op"

# Real tracked and untracked content changes must be committed and pushed.
repo="$(setup_repo changed)"
printf 'changed\n' > "$repo/tracked.txt"
printf 'new\n' > "$repo/new.txt"
output="$(cd "$repo" && "$HELPER" "test: commit real changes")"
[[ "$output" == *"Committed and pushed"* ]] || fail "missing success message"
[[ "$(git -C "$repo" log -1 --pretty=%s)" == "test: commit real changes" ]] || fail "wrong commit message"
[[ -z "$(git -C "$repo" status --porcelain)" ]] || fail "changed repository is dirty"
local_sha="$(git -C "$repo" rev-parse HEAD)"
remote_sha="$(git --git-dir="$TMP_DIR/changed.git" rev-parse main)"
[[ "$local_sha" == "$remote_sha" ]] || fail "commit was not pushed"
git -C "$repo" ls-files --error-unmatch new.txt >/dev/null || fail "untracked file was not committed"
echo "PASS: real changes are committed and pushed"
