# create-pull-request

A first-party composite action (replacement for
[peter-evans/create-pull-request](https://github.com/peter-evans/create-pull-request))
that commits the working tree, pushes a machine-owned head branch, and creates
— or reuses — the pull request for that branch.

```yaml
- uses: xpertss/create-pull-request@<ref>
```

`<ref>` is a commit SHA in machine-managed (projen-generated) workflows or a tag
(e.g. `v1`) in hand-written workflows.

## Inputs

| Input | Required | Default | Notes |
|---|---|---|---|
| `token` | no | `${{ github.token }}` | PAT (e.g. `PROJEN_GITHUB_TOKEN`) recommended so PRs trigger downstream workflows. The PR's `user` field is the **token owner**. |
| `commit-message` | yes | — | Full commit message (subject + body). |
| `branch` | yes | — | Head branch name, e.g. `github-actions/upgrade-main`. Machine-owned; the action force-pushes it. |
| `base` | no | `$GITHUB_REF_NAME` | Base branch for the PR. Pass it explicitly in a `pull_request` context, where `$GITHUB_REF_NAME` is the merge ref, not a branch. |
| `title` | no | first line of `commit-message` | PR title. |
| `body` | no | full `commit-message` | PR body. |
| `labels` | no | — | Comma-separated. Ensured on both the create and the reuse path. |
| `assignees` | no | — | Comma-separated logins. Ensured on both the create and the reuse path. |
| `author` | no | `github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>` | **Commit** author (`Name <email>` form) only. |
| `committer` | no | value of `author` | **Commit** committer (`Name <email>` form) only. |
| `signoff` | no | `true` | Append a `Signed-off-by` trailer. |

Identity semantics: `author`/`committer` affect commit metadata only; the PR's
`user` field is the token owner. The default identity is
`github-actions[bot]` so bot-based automation (auto-approve, branch protection,
authorship rules) behaves as with the evans action.

## Outputs

| Output | Meaning |
|---|---|
| `head-ref` | The head branch name. |
| `head-sha` | SHA of the pushed commit (empty when nothing was pushed). |
| `pull-number` | PR number, or `0` when no PR exists/was created. |
| `pull-request` | PR URL, or empty. |
| `commit-id` | Same as `head-sha` (evans-compatible alias). |

## Required caller permissions

Either a PAT with `contents: write` + `pull-requests: write` (preferred —
current `PROJEN_GITHUB_TOKEN` usage), or the default token with job
`permissions: contents: write, pull-requests: write`.

## Behavior

| Local changes | Open PR for `branch` | Action |
|---|---|---|
| none | any | no commit, no push; output the existing PR if one is open; **green no-op** |
| yes | none | commit → push → `gh pr create` (title, body, labels, assignees) → outputs |
| yes | open | commit → **force-push** `branch` → reuse PR number → update title/body → ensure labels + assignees |
| yes | closed/merged | commit → force-push → `gh pr create` (new PR) |

- **Force-push is required and intentional:** callers check out the latest base
  and apply a fresh patch, so the new history is based on the base, not on the
  previous run's branch. The branch is machine-owned.
- **Labels and assignees are ensured on both create and reuse paths** —
  downstream `auto-approve`/`auto-merge` automation depends on them.
- **Title and body are updated on reuse** to the current run's inputs, so an
  existing open PR always reflects the latest commit.

## Example

```yaml
jobs:
  upgrade:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
    steps:
      - uses: actions/checkout@v7
      - name: Apply dependency upgrade
        run: npx projen upgrade
      - uses: xpertss/create-pull-request@v1
        with:
          token: ${{ secrets.PROJEN_GITHUB_TOKEN }}
          commit-message: "chore(deps): upgrade dependencies"
          branch: github-actions/upgrade-main
          base: main
          labels: dependencies
```

## Testing

`test-dogfood.yml` runs this action **against this repo**, end-to-end, on a
dedicated `test/dogfood` branch: a fixture step creates a real diff, the action
is invoked twice (create path, then re-run path — which must force-push and
reuse the PR, unchanged number), the results are asserted, and a cleanup step
(`if: always()`) closes the PR and deletes the branch.

## Security model

This repo is public; this section is the trust contract.

### Runtime dependency surface (complete)

| Dependency | Source | Why needed |
|---|---|---|
| `bash`, `git` | runner image | core logic |
| `gh` | GitHub first-party, preinstalled on github.com-hosted runners | API + git auth |

No npm install, pip install, Docker image, `curl | bash`, base64 blob, eval of
fetched code, or third-party code at action runtime. This is the whole supply
chain. At CI time (not action runtime) the build/scan workflows additionally
use `apt` packages (shellcheck, yamllint) and the pinned `actionlint` release
binary.

**Minimum `gh` version:** `2.5.0` (JSON output of `gh pr list`/`gh pr create`);
`ubuntu-latest` ships a 2.1xx `gh` (checked 2026-10-05: `gh` 2.102.0 is the
current release). The action uses only long-stable `gh` subcommands.

### Network surface (complete)

| Endpoint | Direction | Auth | Triggered by |
|---|---|---|---|
| `api.github.com` — `GET /repos/{o}/{r}/pulls?head=…` | read | token | `gh pr list` |
| `api.github.com` — `POST /repos/{o}/{r}/pulls` | write | token | `gh pr create` |
| `api.github.com` — `PATCH /repos/{o}/{r}/pulls/{n}` | write | token | `gh pr edit` (title, body, labels, assignees) |
| `https://github.com/{o}/{r}.git` | push | token (via `gh auth setup-git` credential helper) | `git push -f` |

Nothing else. The action does not call any other host or endpoint.

### Env vars read (complete)

`INPUT_*` (action inputs), `GITHUB_REPOSITORY`, `GITHUB_SERVER_URL`,
`GITHUB_REF_NAME`, `GITHUB_OUTPUT`, `GITHUB_WORKSPACE`, `RUNNER_TEMP`.
(`GITHUB_ACTION_PATH` is used by `action.yml` to locate this script.) No other
env is read; no env is dumped to logs.

### Token flow

```
secret (PROJEN_GITHUB_TOKEN / github.token)
  → action input `token`
  → `gh auth login --with-token`   (stored in ~/.config/gh on the ephemeral runner)
  → used for: gh API calls + git push credential helper
```

The token never appears in any command line (no `x-access-token:` push URLs —
`gh auth setup-git` exists precisely to avoid that), is never written to a
persistent path, and is never printed (no `set -x`, no `echo` of the token).

**Push identity:** when `actions/checkout` persists its credential as an
`http.<server-url>/.extraheader` entry (its default on v6+), `git push` would
otherwise send that header alongside the token's credential, breaking the
"push as the token" contract. The action clears the entry for the push command
only, via per-command git config (`git -c`), so the push authenticates
exclusively as the `token`. No git config file is modified.

### Invariants (what this action will never do)

- no writes to the working tree other than the `git add -A`/`git commit` of local changes
- no push to any ref other than the `branch` input (never `main`, never tags, never `--mirror`)
- no tag creation or deletion
- no `gh repo`/admin operations, no workflow dispatch, no issue/comment writes
- no deletion of branches or PRs (cleanup is the *caller's* job)
- no modification of the repository's git config
- no reading of secrets other than the `token` input

### Residual risks (accepted, with mitigations)

| Risk | Mitigation |
|---|---|
| `gh` version drift on `ubuntu-latest` (not version-pinned) | minimum `gh` version declared above; the dogfood workflow runs on every PR and on a schedule and would catch regressions; the action uses only long-stable `gh` subcommands |
| Runner image drift (`ubuntu-latest`) | same as above; pin the runner image in workflows if the org ever requires it |
| Tag mutation (`v1` rewritten) | consumers SHOULD pin by SHA in machine-managed workflows; tag deletion on `main` is blocked by branch protection |
| Third-party **tools** in CI (`actionlint` binary) | pinned release version + SHA-256 recorded in the workflow; upgrades are a reviewed code change, not a silent download |

## How to bump / upgrade consumers

There is no registry: the git repo is the artifact. Releases are cut by
`release.yml` on push to `main` (conventional commits; tag `vX.Y.Z` + GitHub
Release). Consumers:

- **Hand-written workflows** — bump the tag (e.g. `@v1` → `@v2`).
- **Machine-managed (projen-generated) workflows** — pin the commit SHA and
  update it via the consuming repo's `bump` task (resolve latest tag → commit
  SHA → update the `uses:` constant → `npx projen`).

## Out of scope (v1)

- `delete-branch` parity with evans v8 — not used by the org (auto-merge/branch
  protection handles deletion).
- Marketplace listing.
