#!/usr/bin/env bash
# create-pr.sh — commit the working tree, push a machine-owned head branch, and
# create or reuse the pull request for that branch.
#
# Invoked by action.yml (composite action). Runtime dependencies: bash, git and
# gh, all preinstalled on github.com-hosted runners.
#
# Security invariants (see README.md, "Security model"):
#   - $INPUT_TOKEN is passed to `gh auth login` on stdin only. It is never
#     echoed, never placed on a command line, and lands only in ~/.config/gh on
#     the ephemeral runner.
#   - `set -x` must never be enabled in this script or by callers.
#   - The only ref ever pushed is the `branch` input (force-push, intentional).

set -euo pipefail

# Operate on the workspace regardless of the current directory.
cd "${GITHUB_WORKSPACE:-.}"

DEFAULT_IDENTITY='github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>'

# --- inputs ----------------------------------------------------------------

commit_message="${INPUT_COMMIT_MESSAGE:?missing required input: commit-message}"
branch="${INPUT_BRANCH:?missing required input: branch}"
token="${INPUT_TOKEN:?missing input: token (defaults to github.token in action.yml)}"
base="${INPUT_BASE:-${GITHUB_REF_NAME:-}}"
title="${INPUT_TITLE:-}"
body="${INPUT_BODY:-}"
labels="${INPUT_LABELS:-}"
assignees="${INPUT_ASSIGNEES:-}"
author="${INPUT_AUTHOR:-$DEFAULT_IDENTITY}"
committer="${INPUT_COMMITTER:-$author}"
signoff="${INPUT_SIGNOFF:-true}"

if [[ -z "$title" ]]; then
  title="${commit_message%%$'\n'*}"
fi
if [[ -z "$body" ]]; then
  body="$commit_message"
fi

# gh resolves the repo and host from the workflow environment.
export GH_REPO="${GITHUB_REPOSITORY:-}"
gh_hostname="${GITHUB_SERVER_URL#https://}"

# --- helpers ----------------------------------------------------------------

log() {
  echo "[create-pull-request] $*"
}

# Parse `Name <email>`; sets ID_NAME and ID_EMAIL.
parse_identity() {
  local identity="$1"
  ID_NAME="${identity% <*>}"
  ID_EMAIL="${identity##*<}"
  ID_EMAIL="${ID_EMAIL% >}"
  if [[ -z "$ID_NAME" || "$ID_EMAIL" != *@* || -z "$ID_EMAIL" ]]; then
    echo "::error::identity '$identity' is not in 'Name <email>' form" >&2
    exit 1
  fi
}

# Write the action outputs (all single-line values).
write_outputs() {
  local head_ref="$1" head_sha="$2" pull_number="$3" pull_url="$4"
  {
    echo "head-ref=${head_ref}"
    echo "head-sha=${head_sha}"
    echo "pull-number=${pull_number}"
    echo "pull-request=${pull_url}"
    echo "commit-id=${head_sha}"
  } >> "$GITHUB_OUTPUT"
}

# Find an open PR for head branch $1; sets OPEN_PR_NUMBER / OPEN_PR_URL.
find_open_pr() {
  local head="$1"
  OPEN_PR_NUMBER="$(gh pr list --head "$head" --state open --json number --jq '.[0].number // empty')"
  if [[ -n "$OPEN_PR_NUMBER" ]]; then
    OPEN_PR_URL="$(gh pr view "$head" --json url --jq '.url')"
  else
    OPEN_PR_URL=""
  fi
}

# Build --label/--add-label args from the comma-separated $labels input.
# $2 selects the flag: create uses --label, reuse uses --add-label.
label_args=()
add_label_args=()
if [[ -n "$labels" ]]; then
  IFS=',' read -r -a label_arr <<< "$labels"
  for label in "${label_arr[@]}"; do
    label="${label#"${label%%[![:space:]]*}"}"
    label="${label%"${label##*[![:space:]]}"}"
    if [[ -n "$label" ]]; then
      label_args+=("--label" "$label")
      add_label_args+=("--add-label" "$label")
    fi
  done
fi

# Build --assignee/--add-assignee args from the comma-separated $assignees
# input (create uses --assignee, reuse uses --add-assignee).
assignee_args=()
add_assignee_args=()
if [[ -n "$assignees" ]]; then
  IFS=',' read -r -a assignee_arr <<< "$assignees"
  for assignee in "${assignee_arr[@]}"; do
    assignee="${assignee#"${assignee%%[![:space:]]*}"}"
    assignee="${assignee%"${assignee##*[![:space:]]}"}"
    if [[ -n "$assignee" ]]; then
      assignee_args+=("--assignee" "$assignee")
      add_assignee_args+=("--add-assignee" "$assignee")
    fi
  done
fi

# --- validate ---------------------------------------------------------------

if ! git check-ref-format --branch "$branch" >/dev/null; then
  echo "::error::branch '$branch' is not a valid git branch name" >&2
  exit 1
fi
if [[ -z "$base" ]]; then
  echo "::error::no base branch: pass the 'base' input (the \${GITHUB_REF_NAME} default is unavailable here)" >&2
  exit 1
fi
parse_identity "$author"
author_name="$ID_NAME"
author_email="$ID_EMAIL"
parse_identity "$committer"
committer_name="$ID_NAME"
committer_email="$ID_EMAIL"

# --- stage & check ------------------------------------------------------------

git add -A
if git diff --staged --quiet; then
  # No local changes: green no-op. No commit, no push; report an existing open
  # PR for the branch if there is one.
  log "No local changes; nothing to commit or push."
  printf '%s' "$token" | gh auth login --with-token --hostname "$gh_hostname"
  OPEN_PR_NUMBER=""
  OPEN_PR_URL=""
  find_open_pr "$branch"
  if [[ -n "$OPEN_PR_NUMBER" ]]; then
    log "Existing open PR #$OPEN_PR_NUMBER for branch '$branch': $OPEN_PR_URL"
    write_outputs "$branch" "" "$OPEN_PR_NUMBER" "$OPEN_PR_URL"
  else
    log "No open PR for branch '$branch'."
    write_outputs "$branch" "" "0" ""
  fi
  exit 0
fi

# --- auth ---------------------------------------------------------------------

printf '%s' "$token" | gh auth login --with-token --hostname "$gh_hostname"
# Installs the gh credential helper so the push below authenticates without the
# token appearing in any command line or remote URL.
gh auth setup-git

# --- commit ---------------------------------------------------------------------

# Write the message to a file: avoids quoting bugs and keeps the message out of
# the process list.
if [[ -n "${RUNNER_TEMP:-}" ]]; then
  msg_file="${RUNNER_TEMP}/create-pr-commit-message.txt"
else
  msg_file="$(mktemp)"
fi
printf '%s\n' "$commit_message" > "$msg_file"

# Reset/create the head branch at the current HEAD (latest base + local patch).
git checkout -B "$branch"

commit_args=(-F "$msg_file" --author "$author_name <$author_email>")
if [[ "$signoff" =~ ^[Tt][Rr][Uu][Ee]$ ]]; then
  commit_args+=(-s)
fi
GIT_COMMITTER_NAME="$committer_name" \
GIT_COMMITTER_EMAIL="$committer_email" \
git commit "${commit_args[@]}"

head_sha="$(git rev-parse HEAD)"
rm -f "$msg_file"

# --- detect (before the push, so the pre-existing PR state is known) ------------

OPEN_PR_NUMBER=""
OPEN_PR_URL=""
find_open_pr "$branch"

# --- push ---------------------------------------------------------------------

# Force-push is required and intentional: the caller checks out the latest base
# and applies a fresh patch, so the new history is not a descendant of the
# previous run's branch. The branch is machine-owned.
#
# R1: actions/checkout persists the job's GITHUB_TOKEN as an http extraheader
# for the server host (in .git/config, or in an included config file in newer
# checkout versions). Git sends that header on the push and it shadows the
# `gh auth setup-git` credential helper: with a read-only job token the push
# 403s, and with contents:write it goes out as GITHUB_TOKEN instead of the PAT.
# An empty value for http.<url>.extraheader resets the list to empty
# (git-config(1)), and -c has the highest config precedence, so the header is
# cleared for this one command without writing to disk.
log "Force-pushing branch '$branch'."
git -c "http.${GITHUB_SERVER_URL}/.extraheader=" push -f origin "$branch"

# --- pull request ------------------------------------------------------------------

# Write the body to a file: keeps it out of the process list and avoids the
# 128 KiB per-argument limit for long multibyte bodies.
if [[ -n "${RUNNER_TEMP:-}" ]]; then
  body_file="${RUNNER_TEMP}/create-pr-body.txt"
else
  body_file="$(mktemp)"
fi
printf '%s\n' "$body" > "$body_file"

if [[ -n "$OPEN_PR_NUMBER" ]]; then
  # Reuse path: the PR is already open. Update its title and body to the
  # current inputs (the body embeds a per-run workflow URL) and ensure the
  # labels and assignees are present.
  pull_number="$OPEN_PR_NUMBER"
  pull_url="$OPEN_PR_URL"
  log "Reusing open PR #$pull_number for branch '$branch'."
  gh pr edit "$pull_number" --title "$title" --body-file "$body_file" \
    "${add_label_args[@]}" "${add_assignee_args[@]}"
else
  # Create path: no open PR (or only closed/merged ones) for this branch.
  log "Creating a new pull request for branch '$branch' (base '$base')."
  pr_out="$(gh pr create --head "$branch" --base "$base" --title "$title" --body-file "$body_file" \
    "${label_args[@]}" "${assignee_args[@]}" --json number,url --jq '[.number, .url] | @tsv')"
  read -r pull_number pull_url <<< "$pr_out"
  log "Created PR #$pull_number: $pull_url"
fi
rm -f "$body_file"

# --- outputs -----------------------------------------------------------------------

write_outputs "$branch" "$head_sha" "$pull_number" "$pull_url"
log "Done: head-ref='$branch' head-sha='$head_sha' pull-number='$pull_number' pull-request='$pull_url'"
