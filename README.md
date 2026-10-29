# bcgov/actions

[![Issues](https://img.shields.io/github/issues/bcgov/actions)](/../../issues)
[![Pull Requests](https://img.shields.io/github/issues-pr/bcgov/actions)](/../../pulls)
[![Apache-2.0 License](https://img.shields.io/github/license/bcgov/actions.svg)](/LICENSE)
[![Lifecycle](https://img.shields.io/badge/Lifecycle-Experimental-339999)](https://github.com/bcgov/repomountie/blob/master/doc/lifecycle-badges.md)

A centralized repository for custom GitHub Actions and workflows provided to the `bcgov` organization. These are often consumed as part of the [QuickStart for OpenShift](https://github.com/bcgov/quickstart-openshift).


### [builder](./builder/)
Conditional container builder with automatic tag management. Publishes to GitHub Container Registry (`ghcr.io`).

```yaml
- name: Build Container
  uses: bcgov/actions/builder@vX.Y.Z # Replace with latest release tag
```

### [diff-triggers](./diff-triggers/)
Checks git diff for file and path changes to conditionally trigger workflow jobs.

```yaml
- name: Check Triggers
  uses: bcgov/actions/diff-triggers@vX.Y.Z # Replace with latest release tag
```

### [ghcr-cleanup](./ghcr-cleanup/)
Opt-in deletion of closed-PR and unreferenced untagged GHCR versions of the repository's own packages. Dry-run by default.

```yaml
- name: Clean up GHCR
  uses: bcgov/actions/ghcr-cleanup@vX.Y.Z # Replace with latest release tag
  with:
    packages: |
      backend
      frontend
      migrations
```

### [image-tracker](./image-tracker/)
Forensic history traversal to resolve stable image SHAs from Tags or SHAs.

```yaml
- name: Track Images
  uses: bcgov/actions/image-tracker@vX.Y.Z # Replace with latest release tag
```


### [pr-description-add](./pr-description-add/)
Append markdown to a PR description once. Works outside `pull_request` events (e.g. post-deploy) with the `pr` input.

```yaml
- name: PR Description
  uses: bcgov/actions/pr-description-add@vX.Y.Z # Replace with latest release tag
  with:
    markdown: Deployed to TEST
```

### [pr-validate](./pr-validate/)
Validate Pull Request metadata and apply organizational guardrails.

```yaml
- name: Validate PR
  uses: bcgov/actions/pr-validate@vX.Y.Z # Replace with latest release tag
```

### [scan-url](./scan-url/)
Scan a running site's URL with ZAP and Nuclei and upload SARIF to the Security tab.

```yaml
- name: Scan URL
  uses: bcgov/actions/scan-url@vX.Y.Z # Replace with latest release tag
  with:
    url: https://my-app-test.apps.silver.devops.gov.bc.ca
```

### sysdig-monitor (moved)
`sysdig-monitor` moved to [`bcgov/actions-openshift/sysdig-monitor`](https://github.com/bcgov/actions-openshift/tree/main/sysdig-monitor). Update callers to `bcgov/actions-openshift/sysdig-monitor@vX.Y.Z` after that suite releases.

### [test-and-analyse](./test-and-analyse/)
Universal Test and Analyze with Triggers, SonarCloud, and Multi-Language Support. Supports the following runtimes:
- **Node.js**: Testing, dependency analysis with Knip, and safe-chain supply scanning (default).
- **Java**: Maven/Gradle tests and SonarCloud analysis (using input `language: java`).
- **Python**: Pytest runs and JUnit XML parsing (using input `language: python`).
- **Quality gates**: Semgrep (`semgrep_fail`) and a line coverage floor (`min_coverage`) make it a hard PR gate; run one job per package. See [Quality gates](./test-and-analyse/README.md#quality-gates).

```yaml
- name: Test and Analyze
  uses: bcgov/actions/test-and-analyse@vX.Y.Z # Replace with latest release tag
```

### [workflow-notifier](./workflow-notifier/)
Find `CODEOWNERS` and coordinate notifications (GitHub Issues) on job failures.

```yaml
- name: Notify Failures
  uses: bcgov/actions/workflow-notifier@vX.Y.Z # Replace with latest release tag
```

### [workflow-results](./workflow-results/)
Consolidate upstream job results into a single merge gate or workflow rollup with summary tables and error annotations.

```yaml
- name: Workflow Results
  uses: bcgov/actions/workflow-results@vX.Y.Z # Replace with latest release tag
  with:
    needs: ${{ toJson(needs) }}
```

## Security & Token Permissions

In alignment with security best practices, you should always declare minimum explicit permissions for the `GITHUB_TOKEN` in your workflows rather than granting wildcard/admin permissions. 

Refer to each action's directory for its exact minimum required permissions block:
- **[builder](./builder/)**: `contents: read`, `packages: write`, plus `id-token: write` and `attestations: write` (optional, for build provenance attestations)
- **[diff-triggers](./diff-triggers/)**: `contents: read`
- **[ghcr-cleanup](./ghcr-cleanup/)**: `contents: read`, `packages: write`, `pull-requests: read` (`packages: read` for a dry run)
- **[image-tracker](./image-tracker/)**: `contents: read`, `pull-requests: read`, `packages: read`
- **[pr-description-add](./pr-description-add/)**: `pull-requests: write`
- **[pr-validate](./pr-validate/)**: `contents: read`, `pull-requests: read`, plus `pull-requests: write` when `markdown` is set
- **[scan-url](./scan-url/)**: `contents: read`, `issues: write`, `security-events: write`
- **[test-and-analyse](./test-and-analyse/)**: `contents: read`, `actions: write` (optional, for caching)
- **[workflow-notifier](./workflow-notifier/)**: `contents: read`, `issues: write`, `pull-requests: read` (optional, for PR merge author resolution)
- **[workflow-results](./workflow-results/)**: `permissions: {}` (no permissions required)

## Releases and Version Pinning

Never pin `@main`. Pin a [release](../../releases) tag (`@v1.2.3`) or that tag’s commit SHA.

`test-and-analyse` executes `dist/` from ncc. `dist/` is git-ignored and never on `main`. To release, publish `vX.Y.Z` from the GitHub Releases page on the `main` tip; [`.github/workflows/release.yml`](./.github/workflows/release.yml) tags that commit `vX.Y.Z-src`, builds `dist/` on a side commit, moves `vX.Y.Z` onto it, and regenerates the notes; `-src` tags stay permanently ([ADR 0001](./docs/adr/0001-double-tag-release.md)). Pin `vX.Y.Z`, never a `-src` tag. Composite actions in this repo are YAML, but still must not be pinned to `@main`.

### Cutting a release (maintainers)

Publish from the [Releases page](../../releases/new); automation does the rest. **Do not push release tags by hand** (neither `vX.Y.Z` nor `vX.Y.Z-src`); the workflow creates and moves them.

1. On the Releases page, create tag `vX.Y.Z` targeting `main` (the tip) and publish.
2. The [release workflow](./.github/workflows/release.yml) then tags that commit `vX.Y.Z-src`, builds `dist/` on a side commit, moves `vX.Y.Z` onto it, and regenerates the notes from the previous `-src`. For a minute or two `vX.Y.Z` has no `dist/`; wait for the run to go green before pinning.

- **Tag protection is procedural.** This repo has no tag ruleset (only the `main` branch ruleset); that is expected.
- **First release:** delete the old draft `v0.11.0` on the Releases page before the first cut, so nobody publishes it by habit, then publish a fresh `v0.11.0`.
- **Failed run:** a release whose run failed (no `dist/`, or an orphan `vX.Y.Z-src`) is not reused. Fix the cause and publish the next patch version ([ADR 0001](./docs/adr/0001-double-tag-release.md)).

Usage examples use `@vX.Y.Z` — a placeholder that will not resolve — so copy-paste fails until you pick a real tag. All actions are versioned and released together as a single suite.
