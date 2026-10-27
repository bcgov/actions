# PR Validate

Validate Pull Request metadata and apply organizational guardrails to contributor pull requests.

## Features

- ✅ **Conventional Commits**: Enforces semantic pull request titles (e.g. `feat: ...`, `fix: ...`) per [conventionalcommits.org](https://www.conventionalcommits.org/) using `amannn/action-semantic-pull-request`.
- ✅ **Educational UX**: Provides explicit, custom GitHub annotations when title validation fails, instructing contributors exactly how to fix the issue without manually retrying CI.
- ✅ **PR description**: Optional `markdown` is appended to the PR description once (checkbox state is ignored when checking for it).
- ✅ **Fork notice**: Emits a warning on fork pull requests with a link to fork CI configuration guidance. Validation continues (conventional commits, etc.).
- ✅ **Workflow lint**: Runs `rhysd/actionlint` v1.7.12 on Linux x86_64 against every `.yml` and `.yaml` file in `.github/workflows`, hidden files (such as `.reusable.yml`) included. Other runners fail the step. The linux/amd64 tarball is checked against the SHA-256 in `actionlint_1.7.12_checksums.txt` before extraction. Checks the files out with `clean: false` when they are not already in the workspace. A failed download fails the step. The bundled config adds the `ubuntu-26.04` and `ubuntu-26.04-arm` runner labels. If the repo has `.github/actionlint.yaml` (or `.yml`), its `self-hosted-runner` labels are added too; its other settings are not used.
- ✅ **List input format**: Fails when a `bcgov/actions` or `bcgov/actions-openshift` caller passes a shared list input (`triggers`, `packages`, `package`, `tags`, `keep_digests`) in a format the actions do not read. See [List inputs](#list-inputs).

## Permissions

To run this action, the calling workflow job must have the following minimum permissions:

```yaml
permissions:
  contents: read
  pull-requests: read
```

If `markdown` is set, also grant `pull-requests: write`.

## Usage

```yaml
- name: Validate PR
  uses: bcgov/actions/pr-validate@vX.Y.Z # Replace with latest release tag
  # No inputs required — checks PR title and emits a fork notice when applicable.

- name: Validate PR (With Custom Inputs)
  uses: bcgov/actions/pr-validate@vX.Y.Z
  with:
    # Optional: Append markdown to the PR body (skips when empty)
    markdown: |
      ---
      Deployments will be available below.

    # Optional: Authentication token (defaults to github.token; override with PAT if needed)
    token: ${{ secrets.GITHUB_TOKEN }}
```

### Fork pull requests

Fork PRs receive a workflow warning and continue validation. They use read-only tokens on the base repo; `markdown` is skipped on forks with a notice.

## List inputs

`triggers` is the main reason for this check. A `triggers` list the actions cannot read does not always fail loudly: when a PR only changes `.github/workflows`, the build is skipped and pr-close or path filters can miss without anyone noticing. `packages`, `tags` and `keep_digests` use the same parser (`shared/inputs.js` `parseList`), so they are checked the same way.

Allowed:

```yaml
with:
  triggers: |        # one item per line
    backend/
    'my path/'
    src/{a,b}/**     # commas inside {} globs are fine
  packages: backend  # a single value
  tags: ${{ inputs.tags }}  # expressions are not checked
```

Fails:

```yaml
with:
  triggers: backend/, frontend/         # comma-separated
  packages: api frontend                # space-separated
  tags: ('latest' 'prod')               # bash array
  keep_digests: '["sha256:a", "sha256:b"]'  # JSON / bracket list
```

Limits: the check reads workflow files line by line, not as full YAML. It covers each `with:` block whose `uses:` (before or after it, in the same step or job) points at `bcgov/actions` or `bcgov/actions-openshift`. Lines or values containing `${{ }}` are skipped, and YAML anchors, flow mappings (`with: {...}`) and multi-line plain scalars are not checked.
