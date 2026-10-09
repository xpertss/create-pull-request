// .projenrc.ts
import { GitHubActionProject } from '@xpertss/projen-types';

const project = new GitHubActionProject({
  name: 'create-pull-request',
  description:
    'Commit the working tree, push a head branch, and create or reuse the PR for that branch',
  dogfood: {
    // F006's load-bearing behaviors (create path, re-run path) plus the F017
    // parity behaviors, exercised end-to-end against this repo:
    //   R1 - the push must use the action's token even though checkout
    //        persisted a (here invalid) credential as an http extraheader
    //   R2 - the re-run path updates the reused PR's title and body
    //   R3 - the assignees input is honored on create and reuse
    scenario: [
      {
        name: 'Create path',
        id: 'create',
        fixtureSteps: [
          // R3: resolve the PAT owner's login so the `assignees` input can
          // reference it (projen assigns the PR to the token owner).
          "echo \"OWNER_LOGIN=$(GH_TOKEN='${{ secrets.PROJEN_GITHUB_TOKEN }}' gh api user --jq .login)\" >> \"$GITHUB_ENV\"",
          // R1: install a deliberately invalid persisted credential so the
          // push must go through the action's token, not this header.
          'git config --local "http.$GITHUB_SERVER_URL/.extraheader" "AUTHORIZATION: basic aW52YWxpZA=="',
          'echo "$(date -u +%Y%m%dT%H%M%SZ)" >> test/fixtures/dogfood-state.txt',
        ],
        inputs: {
          token: '${{ secrets.PROJEN_GITHUB_TOKEN }}',
          'commit-message': 'test: dogfood ${{ github.run_id }}',
          branch: 'test/dogfood',
          // explicit base: on pull_request triggers $GITHUB_REF_NAME is
          // the PR merge ref (e.g. "123/merge"), not a branch, so the
          // action's default would be an invalid PR base here.
          base: 'main',
          labels: 'dogfood-test',
          assignees: '${{ env.OWNER_LOGIN }}',
          title: 'dogfood create',
          body: 'dogfood create body',
        },
        // the assert step runs under `set -euo pipefail` (added by the
        // package since v0.0.19), so any failing line fails the job
        assertions: [
          '[ "${{ steps.create.outputs.pull-number }}" -gt 0 ]',
          '[ -n "${{ steps.create.outputs.head-sha }}" ]',
          '[ -n "${{ steps.create.outputs.pull-request }}" ]',
          'gh pr view test/dogfood --json state --jq .state | grep -qx open',
          "gh pr view test/dogfood --json labels --jq '.labels[].name' | grep -qx dogfood-test",
          // R3: the PR is assigned to the token owner.
          "gh pr view test/dogfood --json assignees --jq '.assignees[].login' | grep -qx \"$OWNER_LOGIN\"",
          // R1: the credential the fixture installed is still present - the
          // action suppressed it for the push but did not rewrite the config.
          'git config --local --get-all "http.$GITHUB_SERVER_URL/.extraheader" | grep -qx "AUTHORIZATION: basic aW52YWxpZA=="',
        ],
      },
      {
        // Second invocation in the same job: new fixture diff, same branch.
        // The action must force-push and reuse the PR (unchanged number) and
        // update its title and body to the current (different) inputs.
        name: 'Re-run path',
        id: 'rerun',
        fixtureSteps: [
          'echo "$(date -u +%Y%m%dT%H%M%SZ)" >> test/fixtures/dogfood-state.txt',
        ],
        inputs: {
          token: '${{ secrets.PROJEN_GITHUB_TOKEN }}',
          'commit-message': 'test: dogfood ${{ github.run_id }}',
          branch: 'test/dogfood',
          base: 'main',
          labels: 'dogfood-test',
          assignees: '${{ env.OWNER_LOGIN }}',
          title: 'dogfood reuse',
          body: 'dogfood reuse body',
        },
        assertions: [
          '[ "${{ steps.rerun.outputs.pull-number }}" -gt 0 ]',
          '[ "${{ steps.rerun.outputs.pull-number }}" = "${{ steps.create.outputs.pull-number }}" ]',
          // R2: the reused PR's title and body were updated to the new inputs.
          "gh pr view test/dogfood --json title --jq .title | grep -qx 'dogfood reuse'",
          "gh pr view test/dogfood --json body --jq .body | grep -q 'dogfood reuse body'",
          // R3: assignees still present.
          "gh pr view test/dogfood --json assignees --jq '.assignees[].login' | grep -qx \"$OWNER_LOGIN\"",
        ],
      },
    ],
    cleanup: [
      // best-effort (no -e): every line runs regardless of the others
      'set -uo pipefail',
      "gh pr list --head test/dogfood --state open --json number --jq '.[].number' | while read -r n; do gh pr close \"$n\" --yes || true; done",
      'git push origin --delete test/dogfood || true',
      // R1: remove the persisted credential the fixture installed.
      'git config --local --unset-all "http.$GITHUB_SERVER_URL/.extraheader" || true',
    ],
  },
});

project.synth();
