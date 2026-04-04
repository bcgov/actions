# Diff Triggers

Check if changed files match trigger paths. Returns true if any trigger matches, false otherwise. Always returns true if triggers are omitted.

## Features

- **Fork PR Support**: Automatically handles fork and non-fork PRs
- **Push Event Support**: Works with push events for deployer workflows
- **Flexible Ref Comparison**: Compare against any ref (branch, commit SHA, HEAD^, etc.)
- **Smart Path Matching**: Uses git pathspec matching for accurate trigger detection
- **Space Handling**: Properly handles trigger paths containing spaces
- **Visible Logging**: Prominent banners and collapsible details in step logs

## Usage

```yaml
- uses: bcgov/actions/diff-triggers@v1
  with:
    triggers: ('backend/' 'frontend/')
    ref: main
```

## Inputs

| Name | Description | Default |
|------|-------------|---------|
| `triggers` | Paths used to trigger an event; e.g. `('./backend/' './frontend/')`; always trigger if omitted | (none) |
| `ref` | Reference to compare against (e.g., 'main', 'HEAD^', commit SHA). Defaults to base repo default branch for PRs, or HEAD^ for non-PR events | (auto) |
| `annotations` | Emit workflow summary annotations for fired/not fired results | `'true'` |
| `debug` | Enable debug logging | `'false'` |

## Outputs

| Name | Description |
|------|-------------|
| `triggered` | Boolean result - true if any trigger matched |
| `base_ref` | The resolved base ref SHA |
| `head_ref` | The resolved head ref SHA |

## Examples

### Pull Request Event

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
    runs-on: ubuntu-22.04
    steps:
      - uses: bcgov/actions/diff-triggers@v1
        id: test
        with:
          triggers: ('backend/' 'frontend/')
```

### Push Event

```yaml
on:
  push:

jobs:
  check:
    runs-on: ubuntu-22.04
    steps:
      - uses: bcgov/actions/diff-triggers@v1
        with:
          triggers: ('backend/' 'frontend/')
```

### Compare Against Specific Commit

```yaml
- uses: bcgov/actions/diff-triggers@v1
  with:
    triggers: ('backend/')
    ref: abc123def456
```

### Fork PR Support

The action automatically handles fork PRs in `pull_request_target` context:

```yaml
on:
  pull_request_target:

jobs:
  check:
    runs-on: ubuntu-22.04
    steps:
      - uses: bcgov/actions/diff-triggers@v1
        with:
          triggers: ('backend/')
```