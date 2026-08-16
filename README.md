# bcgov/actions

[![Issues](https://img.shields.io/github/issues/bcgov/actions)](/../../issues)
[![Pull Requests](https://img.shields.io/github/issues-pr/bcgov/actions)](/../../pulls)
[![Apache-2.0 License](https://img.shields.io/github/license/bcgov/actions.svg)](/LICENSE)
[![Lifecycle](https://img.shields.io/badge/Lifecycle-Experimental-339999)](https://github.com/bcgov/repomountie/blob/master/doc/lifecycle-badges.md)

A centralized repository for custom GitHub Actions and workflows provided to the `bcgov` organization. These are often consumed as part of the [QuickStart for OpenShift](https://github.com/bcgov/quickstart-openshift).

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

## Security & Token Permissions

In alignment with security best practices, you should always declare minimum explicit permissions for the `GITHUB_TOKEN` in your workflows rather than granting wildcard/admin permissions. 

Refer to each action's directory for its exact minimum required permissions block:
- **[builder-ghcr](./builder-ghcr/)**: `contents: read`, `packages: write`, plus `id-token: write` and `attestations: write` (optional, for build provenance attestations)
- **[diff-triggers](./diff-triggers/)**: `contents: read`
- **[get-pr](./get-pr/)**: `pull-requests: read`, `contents: read` (optional, for offline/fallback commit resolution)
- **[image-tracker](./image-tracker/)**: `contents: read`, `pull-requests: read`, `packages: read`
- **[pr-description-add](./pr-description-add/)**: `pull-requests: write`
- **[sysdig-monitor](./sysdig-monitor/)**: `contents: read` (alert templates are read from the consuming repo's checkout)
- **[test-and-analyse](./test-and-analyse/)**: `contents: read`, `actions: write` (optional, for caching)
- **[workflow-notifier](./workflow-notifier/)**: `contents: read`, `issues: write`

## Releases and Version Pinning

> **Never reference these actions with `@main`.** Always pin to a release tag (e.g. `@v1.2.3`) or, better yet, a full commit SHA.
>
> Usage examples in this repo intentionally use a placeholder that **will not resolve** (`@vX.Y.Z`).  Copy-paste should fail until you look up the [latest release](../../releases) and pick a real version.
>
> All actions in this repository are versioned and released together as a single suite.

## Developing in this repository

Workflows and composite actions in **this** repo reference sibling actions with GitHub's self-repository syntax (`$/`), not `./`:

```yaml
uses: $/diff-triggers          # action at the running commit — no checkout required
uses: $/.github/workflows/.pr-validate.yml  # reusable workflow at the running commit
```

**Consumers** outside this repo still pin published actions normally:

```yaml
uses: bcgov/actions/diff-triggers@vX.Y.Z
```

Internal integration tests live under `.github/workflows/test-*.yml`. When a composite action calls a sibling (e.g. `test-and-analyse` → `$/diff-triggers`), the sibling resolves at the same SHA as the parent — even when downstream callers pin a full commit SHA.

`./` is the trap: it resolves against `GITHUB_WORKSPACE`, not the action's own repo. A test job that checks this repo out at the workspace root makes `./sibling` resolve anyway, so the mistake passes CI and only breaks for consumers. Test jobs that exercise a sibling call must therefore leave the workspace root free of this repo — load the action under test with `$/`, and check any fixture repo out to a subdirectory (`path:`). Jobs whose action needs workspace content of its own (`diff-triggers`, `image-tracker`, `sysdig-monitor`, `workflow-notifier`) still check out at the root; that is fine only while those actions call no siblings.
