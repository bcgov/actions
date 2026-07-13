[![MIT License](https://img.shields.io/github/license/bcgov/actions.svg)](/LICENSE)
[![Issues](https://img.shields.io/github/issues/bcgov/actions)](/../../issues)
[![Pull Requests](https://img.shields.io/github/issues-pr/bcgov/actions)](/../../pulls)

# Lint GitHub Actions Workflows

Lint GitHub Actions workflow files (`.github/workflows/*.yml`) using `rhysd/actionlint` with caching and rate-limit-proof execution.

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
