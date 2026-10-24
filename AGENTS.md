# AGENTS.md

Repository facts for automated coding assistants. Teams may edit or remove this file.

## Image promotion

Pipeline: build, then `image-tracker`, then deploy by digest (`outputs.digest` / `images`). Details: [image-tracker/README.md](image-tracker/README.md).

- Don't use `quickstart-openshift` `.github/workflows/merge.yml` as the image spec. It still promotes mutable `:<pr>` tags via the old standalone `get-pr`.
- A squash merge `HEAD` was never built. Merge/promote must walk far enough to find the last OCI-labeled image per package; `max_depth` defaults to `100`. `max_depth: 1` only asks "was this SHA built?"; it is not merge promotion.
- A miss is `exit 1`. Forks don't change that: no empty-digest skip, no fork `if:`.
- Don't reject a digest because it was built on a different PR (unchanged package).
- Don't re-add `get-pr` (removed; image-tracker replaces it) or retag-by-PR-number as the deploy identity.

## Release ncc bundles

`test-and-analyse/dist/` is git-ignored and never on `main`. Only `.github/workflows/release.yml` commits them, on the release commit.

- Trigger: `release` / `published` on `bcgov/actions`. Do not run it on `pull_request` or `push` to `main`. Do not require a draft release.
- Checkout `github.event.release.tag_name`. Exit 0 when `github.actor` is `github-actions[bot]`, or when `HEAD` subject is `chore(dist): rebuild ncc bundles for release`.
- Otherwise `gh release delete <tag> --yes --cleanup-tag` before `npm ci`. A failed job leaves that tag deleted. Do not delete any other tag.
- Then `npm ci` and `npm run build`. Fail when either `dist/index.js` is missing. Force-add both `dist/` folders (`git add -f`). When they differ, commit that subject and create the tag on the new commit. When they match, create the tag on the original commit. `gh release create` keeps the saved title, notes, and prerelease flag. Do not push `main`. Do not commit `dist/` on pull requests.
- Consumers pin the tag, or that tag's SHA after this workflow succeeds. `@main` does not contain the rebuild. `uses: $/…` in this repo loads the workflow commit, which has no `dist/`. Suite tests build in the job and run `.github/scripts/stage-dist.sh` before `$/test-and-analyse`.

## PR triggers

PR workflows must not fire unnecessarily.

- Gate heavy jobs (matrices, container tests, deploys) with `diff-triggers` or path filters that list only the files each job depends on, never a whole action folder with its README.
- Markdown and docs-only changes never start heavy jobs.
- Skipped jobs still report through `workflow-results`, with the standard job names and no `title`, so required checks stay stable.

## README usage examples

- Usage examples in action READMEs show how `bcgov/quickstart-openshift` would call the action: its workflows (`pr-open.yml`, `pr-close.yml`, `merge.yml`, `scheduled.yml`), its packages (`backend`, `frontend`, `migrations`) and its job order. Add a separate example only when the quickstart shape does not fit. Never say quickstart uses an action it does not use; read its workflows first.

## Suite rollout

`bcgov/actions-openshift` calls `bcgov/actions/*` (`diff-triggers` in `deployer`, `crunchy`, and `oc-runner`; `image-tracker` in `.github/workflows/.deployer.yml`; `diff-triggers` and `workflow-results` in repo workflows), all pinned to the same suite release SHA. Each rollout wave includes the entire suite: release `bcgov/actions` first, bump all `bcgov/actions/*` pins in `bcgov/actions-openshift`, then release `bcgov/actions-openshift` so consumer waves update both suites together.

## Inputs

Read list, boolean, enum and token inputs, and the run's debug state, through [shared/inputs.js](shared/inputs.js), never with ad hoc splitting or string compares. Details: [shared/README.md](shared/README.md).

## Input names

Input and output names follow GitHub's conventions first (actions/checkout and other official `actions/*`), then widely used actions (docker/*, dorny/paths-filter). Invent a name only when no convention exists. Names are snake_case, so a convention's `fetch-depth` is `fetch_depth` here.

| Name | Meaning | Convention |
|---|---|---|
| `repository` | Repository whose images are read (image-tracker only). No action clones another repository; tests check out fixtures with actions/checkout. | actions/checkout `repository` |
| `token` | GitHub token, default `github.token` | actions/checkout `token` |
| `working_directory` | Directory the action works in, relative to the workspace | step `working-directory` |
| `base` | Base that `triggers` are diffed against. Never `ref`, `diff_base`, `diff_branch` or `branch`. | dorny/paths-filter `base` |
| `context`, `file`, `build_args`, `tags` | Image build settings | docker/build-push-action |
| `node_version`, `java_version`, `python_version`, `cache` | Toolchain setup | actions/setup-node, setup-java, setup-python |
| `dry_run` | Log and change nothing | (none) |

## Outputs

Outputs are snake_case. Booleans are `true`/`false`. Lists are JSON arrays and maps are JSON objects, so callers read them with `fromJSON()`. Single-value convenience outputs (e.g. image-tracker `digest`) stay plain strings.
