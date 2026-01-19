# actions

Consolidated repo for bcgov-specific GitHub Actions. Please feel free to contribute!

## Available Actions

### General Actions

- **[report-failures](report-failures/)** - Creates GitHub Issues for deployment failures in test/prod zones with auto-assignment from CODEOWNERS

## Usage

Actions in this repository can be used in your workflows like this:

```yaml
- uses: bcgov/actions/report-failures@main
  with:
    zone: test
```

## Contributing

Please feel free to contribute! When adding new actions:

1. Create a new directory with the action name (no `action-` prefix needed)
2. Include `action.yml` with proper metadata
3. Add a comprehensive `README.md` with usage examples
4. Follow the existing action structure
