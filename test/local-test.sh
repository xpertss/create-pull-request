#!/usr/bin/env bash
# Local functional test harness for create-pr.sh.
#
# Simulates the action's runtime on a github.com runner using only local
# tooling: a real git repo whose `origin` is a local bare repository, a fake
# `gh` CLI, and the GITHUB_* / INPUT_* environment the composite action
# provides. It exercises the state-machine paths:
#
#   create   - local changes, no open PR        -> commit, push, gh pr create
#   reuse    - local changes, open PR present   -> commit, push, gh pr edit
#   no-op    - no local changes                 -> green no-op (no push)
#   no-op+pr - no local changes, open PR        -> reports the open PR
#   plus     - validation failures and the token-on-stdin security invariant
#
# Usage: bash test/local-test.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/create-pr.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
note() { printf '\n== %s ==\n' "$*"; }
ok()   { PASS=$((PASS + 1)); printf '  PASS %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$*"; }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1: expected=[$2] actual=[$3]"; fi; }
assert()    { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1: expected=[$3] actual=[$2]"; fi; }
get_out()   { sed -n "s/^$1=//p" "$OUT" | head -n1; }
is_sha()    { [[ "$1" =~ ^[0-9a-f]{40}$ ]] && echo 1 || echo 0; }

# --- fake gh -----------------------------------------------------------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
# Record every invocation (proves the token is never passed on the command line).
[[ -n "${FAKE_GH_CALL_LOG:-}" ]] && printf '%s\n' "$*" >> "${FAKE_GH_CALL_LOG}"
cmd="${1:-}"; shift || true
sub="${1:-}"; shift || true
case "$cmd:$sub" in
  auth:login)
    tok="$(cat)"
    [[ -n "${FAKE_GH_TOKEN_FILE:-}" ]] && printf '%s' "$tok" > "${FAKE_GH_TOKEN_FILE}"
    printf 'fake gh: authenticated (token length=%s)\n' "${#tok}" >&2
    ;;
  auth:setup-git) : ;;                       # local push needs no credential helper
  pr:list)        if [[ "${FAKE_GH_OPEN_PR:-0}" == "1" ]]; then printf '24680\n'; fi ;;
  pr:view)        printf 'https://github.com/fake/repo/pull/24680\n' ;;
  pr:create)      printf '9999\thttps://github.com/fake/repo/pull/9999\n' ;;
  pr:edit)        : ;;
  *) printf 'fake gh: unknown command: %s %s\n' "$cmd" "$sub" >&2; exit 2 ;;
esac
GH
chmod +x "$TMP/bin/gh"

# --- git fixtures: a base bare origin with an initial `main` commit ----------
# Each scenario gets an isolated copy so a push in one can't leak into another.
git init -q --bare "$TMP/base-origin.git"
git init -q -b main "$TMP/seed"
(
  cd "$TMP/seed"
  git config user.name t; git config user.email t@example.com
  echo base > base.txt
  git add -A; git commit -qm "initial"
  git remote add origin "$TMP/base-origin.git"
  git push -q origin main
)

TOKEN="SECRET-TOKEN-abc123"

# Run one scenario. Sets WORK/OUT/CALLS/TOKENFILE; returns create-pr.sh's exit code.
run_scenario() { # <label> <add-change:yes|no> <open-pr:0|1>
  local label="$1" add_change="$2" open_pr="$3"
  WORK="$TMP/work-$label"; OUT="$TMP/out-$label.txt"
  CALLS="$TMP/calls-$label.log"; TOKENFILE="$TMP/token-$label"
  ORIGIN="$TMP/origin-$label.git"
  cp -r "$TMP/base-origin.git" "$ORIGIN"
  git clone -q "$ORIGIN" "$WORK"
  ( cd "$WORK"; git config user.name t; git config user.email t@example.com )
  [[ "$add_change" == "yes" ]] && echo "change-$label" > "$WORK/change.txt"
  : > "$OUT"; : > "$CALLS"; : > "$TOKENFILE"
  env GITHUB_WORKSPACE="$WORK" GITHUB_OUTPUT="$OUT" GITHUB_REPOSITORY="fake/repo" \
      GITHUB_SERVER_URL="https://github.com" GITHUB_REF_NAME="main" \
      FAKE_GH_CALL_LOG="$CALLS" FAKE_GH_TOKEN_FILE="$TOKENFILE" FAKE_GH_OPEN_PR="$open_pr" \
      INPUT_COMMIT_MESSAGE="test: $label" INPUT_BRANCH="test/dogfood" \
      INPUT_TOKEN="$TOKEN" INPUT_BASE="main" INPUT_LABELS="dogfood-test" \
      PATH="$TMP/bin:$PATH" \
      bash "$SCRIPT"
}

# --- scenario: create --------------------------------------------------------
note "create path (changes, no open PR)"
run_scenario create yes 0
assert_eq "head-ref" "test/dogfood" "$(get_out head-ref)"
assert "head-sha is a real sha" "1" "$(is_sha "$(get_out head-sha)")"
assert_eq "pull-number" "9999" "$(get_out pull-number)"
assert_eq "pull-request" "https://github.com/fake/repo/pull/9999" "$(get_out pull-request)"
assert "gh pr create was called" "1" "$(grep -q 'pr create' "$CALLS" && echo 1 || echo 0)"
assert "gh pr edit NOT called" "0" "$(grep -q 'pr edit' "$CALLS" && echo 1 || echo 0)"
assert "branch pushed to origin" "1" "$(git -C "$ORIGIN" rev-parse --verify -q refs/heads/test/dogfood >/dev/null && echo 1 || echo 0)"
assert_eq "token captured via stdin" "$TOKEN" "$(cat "$TOKENFILE")"
assert "token NOT on gh command line" "0" "$(grep -qF "$TOKEN" "$CALLS" && echo 1 || echo 0)"

# --- scenario: reuse ---------------------------------------------------------
note "reuse path (changes, open PR present)"
run_scenario reuse yes 1
assert_eq "head-ref" "test/dogfood" "$(get_out head-ref)"
assert "head-sha is a real sha" "1" "$(is_sha "$(get_out head-sha)")"
assert_eq "pull-number (reused)" "24680" "$(get_out pull-number)"
assert_eq "pull-request (reused)" "https://github.com/fake/repo/pull/24680" "$(get_out pull-request)"
assert "gh pr edit was called" "1" "$(grep -q 'pr edit' "$CALLS" && echo 1 || echo 0)"
assert "gh pr create NOT called" "0" "$(grep -q 'pr create' "$CALLS" && echo 1 || echo 0)"

# --- scenario: no-op (no changes, no open PR) --------------------------------
note "no-op (no changes, no open PR)"
run_scenario noop no 0
assert_eq "head-sha empty" "" "$(get_out head-sha)"
assert_eq "pull-number 0" "0" "$(get_out pull-number)"
assert "no push (branch absent)" "0" "$(git -C "$ORIGIN" rev-parse --verify -q refs/heads/test/dogfood >/dev/null && echo 1 || echo 0)"
assert "gh pr create NOT called" "0" "$(grep -q 'pr create' "$CALLS" && echo 1 || echo 0)"

# --- scenario: no-op with open PR --------------------------------------------
note "no-op (no changes, open PR present)"
run_scenario nooppr no 1
assert_eq "head-sha empty" "" "$(get_out head-sha)"
assert_eq "pull-number (existing)" "24680" "$(get_out pull-number)"
assert "no push (branch absent)" "0" "$(git -C "$ORIGIN" rev-parse --verify -q refs/heads/test/dogfood >/dev/null && echo 1 || echo 0)"

# --- validation: invalid branch name -----------------------------------------
note "validation (invalid branch name)"
WORK="$TMP/work-badbranch"; git clone -q "$TMP/base-origin.git" "$WORK"
OUT="$TMP/out-badbranch.txt"; CALLS="$TMP/calls-badbranch.log"; TOKENFILE="$TMP/token-badbranch"
: > "$OUT"; : > "$CALLS"; : > "$TOKENFILE"
set +e
env GITHUB_WORKSPACE="$WORK" GITHUB_OUTPUT="$OUT" GITHUB_REPOSITORY="fake/repo" \
    GITHUB_SERVER_URL="https://github.com" GITHUB_REF_NAME="main" \
    FAKE_GH_CALL_LOG="$CALLS" FAKE_GH_TOKEN_FILE="$TOKENFILE" \
    INPUT_COMMIT_MESSAGE="x" INPUT_BRANCH="bad/../branch" INPUT_TOKEN="$TOKEN" \
    INPUT_BASE="main" PATH="$TMP/bin:$PATH" bash "$SCRIPT" 2>"$TMP/err-badbranch.log"
rc=$?
set -e
assert_eq "exits non-zero" "1" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"
assert "reports branch error" "1" "$(grep -q 'not a valid git branch name' "$TMP/err-badbranch.log" && echo 1 || echo 0)"

# --- validation: invalid identity --------------------------------------------
note "validation (invalid identity)"
WORK="$TMP/work-badid"; git clone -q "$TMP/base-origin.git" "$WORK"
OUT="$TMP/out-badid.txt"; CALLS="$TMP/calls-badid.log"; TOKENFILE="$TMP/token-badid"
: > "$OUT"; : > "$CALLS"; : > "$TOKENFILE"
set +e
env GITHUB_WORKSPACE="$WORK" GITHUB_OUTPUT="$OUT" GITHUB_REPOSITORY="fake/repo" \
    GITHUB_SERVER_URL="https://github.com" GITHUB_REF_NAME="main" \
    FAKE_GH_CALL_LOG="$CALLS" FAKE_GH_TOKEN_FILE="$TOKENFILE" \
    INPUT_COMMIT_MESSAGE="x" INPUT_BRANCH="test/dogfood" INPUT_TOKEN="$TOKEN" \
    INPUT_BASE="main" INPUT_AUTHOR="not-an-identity" PATH="$TMP/bin:$PATH" \
    bash "$SCRIPT" 2>"$TMP/err-badid.log"
rc=$?
set -e
assert_eq "exits non-zero" "1" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"
assert "reports identity error" "1" "$(grep -q "is not in 'Name <email>' form" "$TMP/err-badid.log" && echo 1 || echo 0)"

# --- summary -----------------------------------------------------------------
printf '\n== RESULT: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
