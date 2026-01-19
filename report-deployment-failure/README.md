# Report Deployment Failure Action

A reusable GitHub Action for reporting deployment failures. This action creates GitHub issues when deployments fail, automatically assigning them to codeowners from your `CODEOWNERS` file.

## Features

- ✅ Creates issues on deployment failure with conventional commits format
- ✅ Automatically assigns issues to codeowners from `CODEOWNERS` file
- ✅ Case-insensitive CODEOWNERS file discovery
- ✅ Searches GitHub-recognized locations (root, `.github/`, `docs/`)
- ✅ Filters out teams (only assigns individual users)
- ✅ Limits to 10 assignees (GitHub API limit)
- ✅ Includes workflow run link in issue body
- ✅ Graceful error handling for missing CODEOWNERS
- ✅ Fallback to mentions if assignment fails

## Usage

### Basic Usage

```yaml
- uses: bcgov/actions/report-deployment-failure@v1
  if: failure()
  with:
    zone: test
    report_issue: true
```

### With Workflow Run ID

```yaml
- uses: bcgov/actions/report-deployment-failure@v1
  if: failure()
  with:
    zone: prod
    workflow_run_id: ${{ github.run_id }}
    report_issue: true
```

### Full Example in Workflow

```yaml
name: Deploy

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@v4
      - name: Deploy application
        run: ./deploy.sh
  
  report-failures:
    name: Report Failures
    if: failure()
    needs: [deploy]
    runs-on: ubuntu-latest
    permissions:
      issues: write
      contents: read
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 1
      
      - uses: bcgov/actions/report-deployment-failure@v1
        with:
          zone: production
          report_issue: true
```

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `zone` | Deployment zone name (e.g., "test", "prod", "pr-123") | Yes | - |
| `workflow_run_id` | Workflow run ID for linking | No | `${{ github.run_id }}` |
| `report_issue` | Whether to create an issue when deployment fails | No | `false` |
| `token` | GitHub token for creating issues | No | `${{ github.token }}` |

## Outputs

| Output | Description |
|--------|-------------|
| `issue_number` | The number of the created issue |
| `issue_url` | The URL of the created issue |

## How It Works

### Issue Creation

When `report_issue: true` and the action runs:

1. Creates an issue with title: `ci(deploy): deployment failed in {zone}`
2. Issue body includes:
   - Failure message with zone name
   - Link to the workflow run for debugging

### CODEOWNERS Handling

The action automatically finds and parses your `CODEOWNERS` file:

1. **Discovery**: Searches case-insensitively in GitHub-recognized locations:
   - Root directory (`.`)
   - `.github/` directory
   - `docs/` directory

2. **Parsing**: Extracts all users from the file
   - Filters out comment lines (starting with `#`)
   - Removes empty lines
   - Extracts usernames (e.g., `@username`)

3. **Filtering**: 
   - **Teams are filtered out** (those containing `/`, e.g., `@org/team-name`)
   - Only individual users are assigned (GitHub API limitation)

4. **Assignment**:
   - Limits to 10 assignees (GitHub API limit)
   - Warns if more than 10 users found
   - Falls back to mentions if assignment fails

### Error Handling

- **Missing CODEOWNERS**: Creates issue without assignees
- **Assignment failures**: Falls back to mentioning users in issue body
- **API errors**: Logs error but doesn't fail the workflow

## CODEOWNERS Example

```
# Example CODEOWNERS file
*                    @user1 @user2
.github/workflows/   @user3
frontend/            @user4
backend/             @user5 @bcgov/backend-team
```

For a deployment failure, the action will:
- Extract users: `@user1`, `@user2`, `@user3`, `@user4`, `@user5`
- Filter out team: `@bcgov/backend-team` (teams cannot be assigned to issues)
- Assign all 5 individual users to the issue

**Note**: Current implementation extracts all users regardless of path patterns. Path-specific matching is planned for future enhancement.

## Permissions Required

The action requires the following permissions:

```yaml
permissions:
  issues: write      # Required to create issues
  contents: read     # Required to read CODEOWNERS file
```

## Advanced Examples

### Conditional Reporting (Only for Production)

```yaml
- uses: bcgov/actions/report-deployment-failure@v1
  if: failure() && (inputs.zone == 'test' || inputs.zone == 'prod')
  with:
    zone: ${{ inputs.zone }}
    report_issue: true
```

### With Custom Token

```yaml
- uses: bcgov/actions/report-deployment-failure@v1
  if: failure()
  with:
    zone: staging
    report_issue: true
    token: ${{ secrets.CUSTOM_GITHUB_TOKEN }}
```

## Future Enhancements

The following features are planned for future releases:

- [ ] Path matching using npm package (`@nmann/codeowners` or `codeowners`)
- [ ] Expand teams to individual members for assignment (using Teams API)
- [ ] Support custom issue labels
- [ ] Support custom issue assignees (override CODEOWNERS)
- [ ] Support issue templates
- [ ] Configurable issue title/body format

## Migration from Inline Script

If you're currently using inline `actions/github-script@v7` logic:

**Before:**
```yaml
- name: Report Failures
  uses: actions/github-script@v7
  with:
    script: |
      # ... inline script logic ...
```

**After:**
```yaml
- uses: bcgov/actions/report-deployment-failure@v1
  with:
    zone: test
    report_issue: true
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

Apache-2.0 License - see [LICENSE](../../LICENSE) for details.

## Support

For issues, questions, or contributions, please use the [GitHub Issues](https://github.com/bcgov/actions/issues) page.
