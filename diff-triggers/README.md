## ⚠️ BREAKING CHANGES in v2.0

- **Rewritten in Node.js** — The action now uses `node24` instead of a composite bash script
- **Checkout is required** — Callers must add an `actions/checkout` step before invoking this action. The action no longer performs its own checkout.
- **`diff_branch` replaced with `ref`** (since v1.0), which supports branches, commit SHAs, tags, and relative refs

---

# Diff File Changes with Triggers

Check triggers against a diff of changed files. Supports PR events (including fork PRs), push events, workflow_dispatch, and other GitHub Actions events. Useful for conditional builds and deployments based on file changes.

## Features

- ✅ **Fork PR Support**: Handles fork and non-fork PRs (caller must checkout the correct ref)
- ✅ **Push Event Support**: Works with push events for deployer workflows
- ✅ **Flexible Ref Comparison**: Compare against any ref (branch, commit SHA, HEAD^, etc.)
- ✅ **Smart Path Matching**: Uses git pathspec matching for accurate trigger detection
- ✅ **Multiple Trigger Formats**: JSON arrays, comma/semicolon/space-separated, and bash-style parenthesized lists
- ✅ **Visible Logging**: Prominent banners and collapsible details in step logs, plus notice annotations in workflow summary and annotations views

## Trigger Formats

The action supports multiple formats for the `triggers` input:

| Format | Example |
|---|---|
| Parenthesized (bash-style) | `('backend/' 'frontend/')` |
| JSON array | `["backend/", "frontend/"]` |
| Comma-separated | `backend/,frontend/` |
| Semicolon-separated | `backend/;frontend/` |
| Space-separated | `backend/ frontend/` |

# Usage

```yaml
steps:
  - uses: actions/checkout@v6
  - uses: bcgov/actions/diff-triggers@vX.Y.Z
    with:
      ### Recommended

      # Paths used to check against file change (diff)
      # Supports multiple formats (see Trigger Formats above)
      # If omitted, the action always fires
      triggers: ('backend/' 'frontend/')

      ### Optional

      # Reference to compare against
      # - PR events: defaults to base repo default branch
      # - Other events (push, workflow_dispatch, etc.): defaults to HEAD^
      ref: main  # Branch, commit SHA, tag, or local ref (HEAD^, HEAD~2). Local refs work for non-PR events only

      # Specify token (GH or PAT), instead of inheriting one from the calling workflow
      github_token: ${{ github.token }}

      # Emit workflow summary/annotations notices (default: true)
      # Set false to suppress notices while keeping step logs
      annotations: true
```

# Output

Returns `triggered: true` if triggers fire, `triggered: false` otherwise.

# Logging & Visibility

The action provides detailed logging directly in the step output for easy debugging and visibility:

- **Banner** — A collapsible group clearly showing triggered/not-triggered status, with supplementary caller context in brackets: `[workflow / job]`
- **Collapsible details** — Trigger configuration and per-trigger match results inside the group
- **Ref source** — Shows whether comparison ref came from explicit input (`input`) or default behavior (`default`)
- **Annotations** — Optional `::notice::` annotations (enabled by default; `annotations: true`) that appear in the workflow summary and annotations tab (e.g., `::notice title=Diff Triggers::✅ Fired. Triggers: ('backend/')`)

# Examples

## Pull Request Event (Typical Pattern)

Check if files have changed, then do something else. This is useful for cases like builds, where a job is usually only needed conditionally.

Please replace `@vX.Y.Z` with the latest version number.

```yaml
on:
  pull_request:

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  check:
    name: Check Triggers Against Diff
    outputs:
      triggered: ${{ steps.test.outputs.triggered }}
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v6
      - uses: bcgov/actions/diff-triggers@vX.Y.Z
        id: test
        with:
          triggers: ('backend/' 'frontend/')

  build:
    name: Build if Triggered
    needs: [check]
    if: needs.check.outputs.triggered == 'true'
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v6
      - name: Build
        run: |
          echo "Building because triggers matched!"
```

## Push Event

Compare current commit to previous commit (HEAD vs HEAD^):

```yaml
on:
  push:

jobs:
  check:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v6
      - uses: bcgov/actions/diff-triggers@vX.Y.Z
        id: test
        with:
          triggers: ('backend/' 'frontend/')
          # ref defaults to HEAD^ for push events
```

## Workflow Dispatch Event

Works with manual triggers and other events. Defaults to comparing HEAD vs HEAD^:

```yaml
on:
  workflow_dispatch:

jobs:
  check:
    name: Check Triggers
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v6
      - uses: bcgov/actions/diff-triggers@vX.Y.Z
        with:
          triggers: ('backend/')
          # ref defaults to HEAD^ for non-PR events
          # Can override: ref: main
```

## Compare Against Specific Commit

```yaml
steps:
  - uses: actions/checkout@v6
    with:
      fetch-depth: 0
  - uses: bcgov/actions/diff-triggers@vX.Y.Z
    with:
      triggers: ('backend/')
      ref: abc123def456  # Compare against specific commit
```

## Fork PR Support

For fork PRs, ensure your checkout step references the correct head:

```yaml
on:
  pull_request_target:

jobs:
  check:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v6
        with:
          repository: ${{ github.event.pull_request.head.repo.full_name }}
          ref: ${{ github.event.pull_request.head.sha }}
      - uses: bcgov/actions/diff-triggers@vX.Y.Z
        with:
          triggers: ('backend/')
```
