
# Lint GitHub Actions Workflows

Lint GitHub Actions workflow files (`.github/workflows/*.yml`) using `rhysd/actionlint` with caching and rate-limit-proof execution.

## Why Actionlint?

GitHub Actions does not validate workflow syntax or expressions when a pull request is submitted. Instead, invalid syntax or bad expressions only fail when the workflow is triggered, which often leads to broken pipelines on `main` or failed release events.

`actionlint` acts as a static analysis tool in our validation pipelines to catch issues early:
1. **Expression Syntax Validation**: Detects typos in GitHub context expressions (e.g., `${{ github.evnet }}` instead of `${{ github.event }}`).
2. **Security & Injection Checks**: Flags patterns that can lead to shell injection (e.g., interpolating untrusted `${{ }}` values into shell commands without proper quoting/sanitization; prefer passing via `env:` and quoting expansions).
3. **Execution Guardrails**: Prevents deploying workflows with missing keys, incorrect permissions, or unexpected/unknown workflow properties.

## Features

- ✅ **Automatic Caching**: Caches the `actionlint` binary locally to speed up subsequent workflow runs.
- ✅ **Rate-Limit Resilient**: Downloads the executable directly from GitHub Releases rather than raw CDN endpoints, avoiding rate-limit issues on runners.
- ✅ **Configurable version**: Pin a specific version of `actionlint` to run.
- ✅ **Custom Arguments**: Pass any standard `actionlint` command-line arguments.

## Usage

```yaml
- name: Lint Workflows
  uses: bcgov/actions/actionlint@vX.Y.Z
  with:
    # Optional: Pinned version tag of rhysd/actionlint to run
    # Default: "v1.7.12"
    version: "v1.7.12"

    # Optional: Additional command line arguments to pass to actionlint
    # Default: ""
    args: "-color"
```
