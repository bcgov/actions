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

### [dast](./dast/)
Run ZAP and Nuclei against one URL (default: the repo's Silver test route) and upload SARIF to the Security tab.

```yaml
- name: DAST
  uses: bcgov/actions/dast@vX.Y.Z # Replace with latest release tag
```

### [diff-triggers](./diff-triggers/)
Checks git diff for file and path changes to conditionally trigger workflow jobs.

```yaml
- name: Check Triggers
  uses: bcgov/actions/diff-triggers@vX.Y.Z # Replace with latest release tag
```


### [image-tracker](./image-tracker/)
Forensic history traversal to resolve stable image SHAs from Tags or SHAs.

```yaml
- name: Track Images
  uses: bcgov/actions/image-tracker@vX.Y.Z # Replace with latest release tag
```

### [pr-description-add](./pr-description-add/)
Add markdown content to Pull Request descriptions dynamically.

```yaml
- name: Update PR Description
  uses: bcgov/actions/pr-description-add@vX.Y.Z # Replace with latest release tag
```

### [pr-validate](./pr-validate/)
Validate Pull Request metadata and apply organizational guardrails.

```yaml
- name: Validate PR
  uses: bcgov/actions/pr-validate@vX.Y.Z # Replace with latest release tag
```

### [sysdig-monitor](./sysdig-monitor/)
Create or update Sysdig email alerts for an app on PROD deploy. Idempotent, additive and non-blocking.

```yaml
- name: Sysdig Monitoring
  uses: bcgov/actions/sysdig-monitor@vX.Y.Z # Replace with latest release tag
```

### [test-and-analyse](./test-and-analyse/)
Universal Test and Analyze with Triggers, SonarCloud, and Multi-Language Support. Supports the following runtimes:
- **Node.js**: Testing, dependency analysis with Knip, and safe-chain supply scanning (default).
- **Java**: Maven/Gradle tests and SonarCloud analysis (using input `language: java`).
- **Python**: Pytest runs and JUnit XML parsing (using input `language: python`).

```yaml
- name: Test and Analyze
  uses: bcgov/actions/test-and-analyse@vX.Y.Z # Replace with latest release tag
```

### ~~test-and-analyse-java~~ (Consolidated)
**Deprecated**: This Java-specific utility has been consolidated into [test-and-analyse](./test-and-analyse/). Please migrate to `test-and-analyse` with `language: java` specified.


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
- **[dast](./dast/)**: `contents: read`, `issues: write`, `security-events: write`
- **[diff-triggers](./diff-triggers/)**: `contents: read`
- **[image-tracker](./image-tracker/)**: `contents: read`, `pull-requests: read`, `packages: read`
- **[pr-description-add](./pr-description-add/)**: `pull-requests: write`
- **[pr-validate](./pr-validate/)**: `pull-requests: read`, plus `pull-requests: write` when `add_markdown` is set
- **[sysdig-monitor](./sysdig-monitor/)**: `contents: read` (alert templates are read from the consuming repo's checkout)
- **[test-and-analyse](./test-and-analyse/)**: `contents: read`, `actions: write` (optional, for caching)
- **[workflow-notifier](./workflow-notifier/)**: `contents: read`, `issues: write`, `pull-requests: read` (optional, for PR merge author resolution)
- **[workflow-results](./workflow-results/)**: `permissions: {}` (no permissions required)

## Releases and Version Pinning

Never pin `@main`. Pin a [release](../../releases) tag (`@v1.2.3`) or that tag’s commit SHA.

`pr-description-add` and `test-and-analyse` execute committed `dist/` from ncc. Pull requests compile that bundle in the job and do not commit it. Publishing a release from the Releases page runs [`.github/workflows/release.yml`](./.github/workflows/release.yml). Unless this run is the workflow republishing the tag, or the tag already points at the dist rebuild, the workflow deletes that release and its git tag before `npm ci`. It then builds. When `pr-description-add/dist/` or `test-and-analyse/dist/` differ, it commits `chore(dist): rebuild ncc bundles for release` and creates the tag on that commit. When they match, it creates the tag on the commit you released. The GitHub Release is recreated with the same title and notes. It does not push `main`. While the job runs, and if the job fails, the tag does not resolve. Copy the pin SHA after the workflow succeeds. `@main` does not contain this rebuild. Composite actions in this repo are YAML, but still must not be pinned to `@main`.

Usage examples use `@vX.Y.Z` — a placeholder that will not resolve — so copy-paste fails until you pick a real tag. All actions are versioned and released together as a single suite.
