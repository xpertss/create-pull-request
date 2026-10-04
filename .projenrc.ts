// .projenrc.ts
import { GitHubActionProject } from '@xpertss/projen-types';

const project = new GitHubActionProject({
  name: 'create-pull-request',
  description:
    'Commit the working tree, push a head branch, and create or reuse the PR for that branch',
  sonarHostUrl: 'https://sonarcloud.io',
  dogfood: {
    // F006's load-bearing behaviors, exercised end-to-end against this
    // repo: the create path (commit, push, open PR) and the re-run path
    // (force-push and reuse the open PR - unchanged number). The re-run
    // path is what the nightly dependency-upgrade flow depends on.
    scenario: [
      {
        name: 'Create path',
        id: 'create',
        fixtureSteps: [
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
        },
        assertions: [
          // GH `run:` fails a step only on the LAST line's exit code, so
          // set -e is needed for multi-line assertions to be effective.
          // (filed as a defect against @xpertss/projen-types)
          'set -euo pipefail',
          '[ "${{ steps.create.outputs.pull-number }}" -gt 0 ]',
          '[ -n "${{ steps.create.outputs.head-sha }}" ]',
          '[ -n "${{ steps.create.outputs.pull-request }}" ]',
          'gh pr view test/dogfood --json state --jq .state | grep -qx open',
          "gh pr view test/dogfood --json labels --jq '.labels[].name' | grep -qx dogfood-test",
        ],
      },
      {
        // Second invocation in the same job: new fixture diff, same
        // branch. The action must force-push and reuse the PR - the
        // number must be unchanged from the create path.
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
        },
        assertions: [
          'set -euo pipefail',
          '[ "${{ steps.rerun.outputs.pull-number }}" -gt 0 ]',
          '[ "${{ steps.rerun.outputs.pull-number }}" = "${{ steps.create.outputs.pull-number }}" ]',
        ],
      },
    ],
    cleanup: [
      // best-effort (no -e): every line runs regardless of the others
      'set -uo pipefail',
      "gh pr list --head test/dogfood --state open --json number --jq '.[].number' | while read -r n; do gh pr close \"$n\" --yes || true; done",
      'git push origin --delete test/dogfood || true',
    ],
  },
});

project.synth();
