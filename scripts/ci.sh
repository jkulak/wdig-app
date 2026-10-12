#!/usr/bin/env bash
# The gate before a merge, on the Mac the build ships from.
#
# There is no hosted runner: a macOS job would re-run the same tests on a machine
# the release is never built on. What a runner did that `make test` does not is
# check a clean copy of the merge result rather than whatever is in the working
# tree, so this does that: a throwaway worktree of HEAD with the base branch
# merged into it, then lint, build and tests in that order.
#
# No arguments, and it stops at the first failure. BASE names a base branch
# other than main. The last line printed is the one for the pull request body.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
ROOT=$(pwd)

BASE=${BASE:-main}
BRANCH=$(git rev-parse --abbrev-ref HEAD)
HEAD_SHA=$(git rev-parse --short HEAD)
LOG="$ROOT/build-gate.log"

if [[ -n $(git status --porcelain) ]]; then
  echo "! the working tree has changes; this checks the last commit, not them"
fi

SCRATCH=$(mktemp -d)
WORK="$SCRATCH/gate"
cleanup() {
  git worktree remove --force "$WORK" >/dev/null 2>&1 || true
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

echo "▸ a clean checkout of $BRANCH ($HEAD_SHA)"
git worktree add --quiet --detach "$WORK" HEAD

MERGED="on its own"
if [[ $BRANCH != "$BASE" ]] && git rev-parse --verify --quiet "$BASE" >/dev/null; then
  echo "▸ with $BASE merged in, which is what merging would produce"
  git -C "$WORK" -c user.name=gate -c user.email=gate@localhost \
      merge --quiet --no-edit "$BASE" \
    || { echo "✗ $BASE does not merge into $BRANCH cleanly; merge it here and resolve first"; exit 1; }
  MERGED="merged with $BASE"
fi

echo "▸ lint"
if ! (cd "$WORK" && make --no-print-directory lint) > "$LOG" 2>&1; then
  grep -E "warning:|error:" "$LOG" | head -20
  echo "✗ lint failed; full log: $LOG"
  exit 1
fi

echo "▸ build and tests on a simulator"
if ! (cd "$WORK" && ./scripts/test.sh test) > "$LOG" 2>&1; then
  grep -E " error:|✘|Testing failed|failed after" "$LOG" | head -20
  echo "✗ the gate failed; full log: $LOG"
  exit 1
fi
TESTS=$(xcrun xcresulttool get test-results summary --path "$WORK/build-sim/TestResults.xcresult" --format json \
  | python3 -c 'import json, sys; d = json.load(sys.stdin); print("%d tests passed, %d failed, %d skipped" % (d["passedTests"], d["failedTests"], d["skippedTests"]))')
rm -f "$LOG"

echo
echo "▸ the gate passed. For the pull request:"
echo "\`make ci\`: ${TESTS:-tests passed} — $BRANCH ($HEAD_SHA), $MERGED."
