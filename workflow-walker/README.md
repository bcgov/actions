# workflow-walker

Forensic Git-history walker for multi-image deployments.

## Usage

```yaml
- uses: bcgov/actions/workflow-walker@v1
  with:
    token: ${{ secrets.GITHUB_TOKEN }}
```

## Inputs

| Name | Description | Default |
|------|-------------|---------|
| `token` | GitHub token | `${{ github.token }}` |
| `debug` | Enable debug logging | `false` |
