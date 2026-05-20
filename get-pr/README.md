# get-pr

Get PR number for merge queues, squash merges, and releases

## Usage

```yaml
- uses: bcgov/actions/get-pr@v1
  with:
    github_token: ${{ secrets.GITHUB_TOKEN }}
```

## Inputs

| Name | Description | Default |
|------|-------------|---------|
| `github_token` | GitHub token | `${{ github.token }}` |
| `debug` | Enable debug logging | `false` |
