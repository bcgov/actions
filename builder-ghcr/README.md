# builder-ghcr

Consolidated container builder action for GitHub Container Registry.

## Usage

```yaml
- uses: bcgov/actions/builder-ghcr@v1
  with:
    token: ${{ secrets.GITHUB_TOKEN }}
```

## Inputs

| Name | Description | Default |
|------|-------------|---------|
| `token` | GitHub token | `${{ github.token }}` |
| `debug` | Enable debug logging | `false` |
