# diff-triggers

Check if changed files match trigger paths

## Usage

```yaml
- uses: bcgov/actions/diff-triggers@v1
  with:
    triggers: './src/' './tests/'
    ref: 'main'
```

## Inputs

| Name | Description | Default |
|------|-------------|---------|
| `triggers` | Space-separated glob patterns for triggering paths | `''` (always trigger) |
| `ref` | Comparison reference (branch/SHA) | Base branch for PRs, HEAD^ for pushes |
| `annotations` | Emit workflow summary annotations | `'true'` |
| `debug` | Enable debug logging | `'false'` |
