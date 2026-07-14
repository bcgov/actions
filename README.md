# bcgov/actions

[![Issues](https://img.shields.io/github/issues/bcgov/actions)](/../../issues)
[![Pull Requests](https://img.shields.io/github/issues-pr/bcgov/actions)](/../../pulls)
[![Apache-2.0 License](https://img.shields.io/github/license/bcgov/actions.svg)](/LICENSE)
[![Lifecycle](https://img.shields.io/badge/Lifecycle-Experimental-339999)](https://github.com/bcgov/repomountie/blob/master/doc/lifecycle-badges.md)

A centralized repository for custom GitHub Actions and workflows provided to the `bcgov` organization. These are often consumed as part of the [QuickStart for OpenShift](https://github.com/bcgov/quickstart-openshift).

### [actionlint](./actionlint/)
Lint GitHub Actions workflow files with caching and rate-limit proof execution.

```yaml
- name: Lint Workflows
  uses: bcgov/actions/actionlint@vX.Y.Z # Replace with latest release tag
```

### [builder-ghcr](./builder-ghcr/)
Generic GHCR container builder with automatic tag management.

```yaml
- name: Build Container
  uses: bcgov/actions/builder-ghcr@vX.Y.Z # Replace with latest release tag
```

### [diff-triggers](./diff-triggers/)
Checks git diff for file and path changes to conditionally trigger workflow jobs.

```yaml
- name: Check Triggers
  uses: bcgov/actions/diff-triggers@vX.Y.Z # Replace with latest release tag
```

### [get-pr](./get-pr/)
Resolve the Pull Request number for merge queues, squash merges, pushes, and releases.

```yaml
- name: Get PR Number
  uses: bcgov/actions/get-pr@vX.Y.Z # Replace with latest release tag
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

### [test-and-analyse](./test-and-analyse/)
Universal Test and Analyze with Triggers, SonarCloud, and Multi-Language Support.

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

## Releases and Version Pinning

> **Never reference these actions with `@main`.** Always pin to a release tag (e.g. `@v1.2.3`) or, better yet, a full commit SHA.
>
> Usage examples in this repo intentionally use `@vX.Y.Z` — a placeholder that **will not resolve**. This is by design.  Copy-paste should fail until you look up the [latest release](../../releases) and pick a real version.
>
> All actions in this repository are versioned and released together as a single suite.
