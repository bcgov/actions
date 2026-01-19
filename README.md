# actions
Consolidated repo for bcgov-specific actions. Please feel free to contribute!

## Available Actions

### report-deployment-failure

A reusable GitHub Action for reporting deployment failures. Creates GitHub issues when deployments fail, automatically assigning them to codeowners.

**Features:**
- ✅ Conventional commits format for issue titles
- ✅ Automatic codeowner assignment from CODEOWNERS file
- ✅ Team filtering (only assigns individual users)
- ✅ Graceful error handling with fallback to mentions

**Usage:**
```yaml
- uses: bcgov/actions/report-deployment-failure@v1
  if: failure()
  with:
    zone: production
    report_issue: true
    token: ${{ github.token }}
```

**Documentation:** See [report-deployment-failure/README.md](./report-deployment-failure/README.md)

## Contributing

Contributions are welcome! Please submit a Pull Request.

## License

Apache-2.0 License - see [LICENSE](LICENSE) for details.
