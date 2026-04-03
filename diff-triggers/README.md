# diff-triggers

Check if changed files match trigger paths

## Usage

```yaml
- uses: bcgov/actions/diff-triggers@v1
  with:
    token: ${{ secrets.GITHUB_TOKEN }}
```

## Inputs

| Name | Description | Default |
|------|-------------|---------|
| `token` | GitHub token | `${{ github.token }}` |
| `debug` | Enable debug logging | `false` |
