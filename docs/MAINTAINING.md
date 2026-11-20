# Maintaining `bcgov/actions`

Guide for repository maintainers covering releases, downstream rollout, and common pitfalls.

## Cutting a release

All actions in this repository share one SemVer release tag (`vX.Y.Z`). Never push release tags (`vX.Y.Z` or `vX.Y.Z-src`) by hand; [`.github/workflows/release.yml`](../.github/workflows/release.yml) builds and tags the `ncc` bundle automatically ([ADR 0001](adr/0001-double-tag-release.md)).

1. Confirm `main` is green (`CodeQL` and the PR checks on the last merged PR).
2. Open the [New Release page](../../releases/new).
3. Enter a new `vX.Y.Z` tag targeting `main` (tip of `main`) and publish the release.
4. Wait for the **Release** workflow run to finish before pinning or announcing the tag:
   - It tags the `main` commit permanently as `vX.Y.Z-src`.
   - It builds `test-and-analyse/dist/` on a side commit (never pushed to `main`) and moves `vX.Y.Z` onto that commit.
   - It regenerates the release notes from the previous `v*-src` tag to `vX.Y.Z-src`.
5. If a release run fails (leaving `vX.Y.Z` without `dist/`, or leaving an orphan `vX.Y.Z-src` tag), **do not reuse or delete `vX.Y.Z`**. Fix the issue on `main` and publish the next patch version (`vX.Y.(Z+1)`).

## How consumers pick up changes

Downstream repositories pin releases by full 40-character commit SHA with a `# vX.Y.Z` comment—never `@main` and never `vX.Y.Z-src`.

Rollout order across the suite:

1. **Release `bcgov/actions`** (`vX.Y.Z` workflow completes and `vX.Y.Z` points to the `dist/` commit).
2. **Update `bcgov/actions-openshift`**: bump all `bcgov/actions/*` pins (in `deployer`, `crunchy`, `oc-runner`, `.github/workflows/`) to the new `bcgov/actions` release SHA, then release `bcgov/actions-openshift`.
3. **Canaries and Renovate consumers**: Renovate opens SHA-pin bump PRs (using `bcgov/renovate-config`) for canary repositories first, followed by remaining adopters once canary runs stay green.

## Common pitfalls

- **Pinning `@main` or `-src` breaks `test-and-analyse`:** `test-and-analyse/dist/` is git-ignored on `main` and only exists on the release side commit pointed to by `vX.Y.Z`.
- **Pinning during the release window:** Between clicking *Publish release* and `.github/workflows/release.yml` finishing (~1–2 minutes), `vX.Y.Z` still points at the `main` commit without `dist/`. Wait for the Release workflow to succeed before copying the tag's commit SHA.
- **Self-repo tests with `uses: $/...`:** Inside `bcgov/actions` pull requests, `$/test-and-analyse` runs the workflow commit, which lacks `dist/`. Suite jobs that test `test-and-analyse` must build and run [`.github/scripts/stage-dist.sh`](../.github/scripts/stage-dist.sh) first.
- **`input-enforcer` fails on unknown or removed keys:** Every composite action runs `input-enforcer` first. Passing an old or misspelled input (even as `""`) fails the step immediately. Keep caller examples minimal ([ADR 0006](adr/0006-callers-use-action-defaults.md)).
- **Strict input formatting ([`shared/inputs.js`](../shared/inputs.js)):** List inputs expect one item per line (multiline YAML string) or a single value—JSON arrays, parenthesized lists, or comma/space-separated items fail fast. Booleans accept only `true`/`false`.
- **Workflow path filters on PRs:** Heavy test jobs in [`.github/workflows/test.yml`](../.github/workflows/test.yml) are gated by `diff-triggers`. When adding or renaming action files, verify the filter paths cover implementation and test files without triggering heavy jobs on `*.md` / `docs/` changes.
