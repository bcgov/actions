# Consolidate GitHub Actions into Two Repositories

## Overview

This plan consolidates scattered bcgov GitHub Actions into two centralized repositories:

- **bcgov/actions** (current repo): For non-OpenShift/general actions
- **bcgov/actions-openshift**: For OpenShift-specific actions

Each action will live in its own subdirectory within the appropriate repository.

**Status (2026-09):** The general suite in `bcgov/actions` is feature-complete for the
`v1.0.0` stabilization epic (#209): `builder/` (renamed from `builder-ghcr`),
`diff-triggers`, `image-tracker` (replaces `get-pr`, removed in v0.11.0), and the other
actions listed below. **`bcgov/actions-openshift`** exists and holds the OpenShift
actions, including `deployer/` (formerly `action-deployer-openshift`). `action-postgres`
was not migrated.

## Versioning Strategy

All actions in each repository are versioned and released together as a **single suite**. A single semver tag (e.g. `v1.2.3`) on the repository applies to every action simultaneously.

> **Consumers must never pin to `@main`.** README examples use `@vX.Y.Z` — a placeholder that will not resolve — to force consumers to look up the [latest release](../../releases) and pick a real version or SHA.
>
> `test-and-analyse` runs ncc `dist/`, which is never on `main`. Publishing a release deletes that tag until `.github/workflows/release.yml` recreates it on the dist commit. `@main` for that action does not run current source.

## Repository Structure

### bcgov/actions (General Actions - Current Repo)

```
actions/
├── builder/
├── diff-triggers/
├── ghcr-cleanup/
├── image-tracker/
├── pr-validate/
├── scan-url/
├── sysdig-monitor/
├── test-and-analyse/
├── workflow-notifier/  # (Formerly report-failures)
├── workflow-results/
├── README.md
└── LICENSE
```

### bcgov/actions-openshift (OpenShift Actions)

```
actions-openshift/
├── cert-expiry/
├── cleanup-pr/
├── crunchy/
├── deployer/
├── image-import/
├── oc-runner/
├── pg-upgrade/
├── route-tls/
├── README.md
└── LICENSE
```

## Migration Strategy

**Phase 1: Assessment & Setup**
- [x] Create `bcgov/actions` (using current repo)
- [x] Create `bcgov/actions-openshift`
- [x] Establish repository structure and documentation standards

**Phase 2: Migration with Backwards Compatibility** *(general suite)*
1. [x] Migrate general actions into `bcgov/actions` subdirectories (`builder/`, etc.).
2. [x] Add **::warning::** notices with the new paths to the old standalone action repositories. *(Thin wrappers were abandoned due to logging problems.)*

**Phase 3: Update Workflows**
1. [x] Update internal suite workflows to sibling `uses: $/…` paths.
2. [ ] After a release that includes the `builder-ghcr` → `builder` rename: notify soak-group adopters (#214). Never pin consumers to `@main` or a commit SHA.
3. [ ] After `v1.0.0`: archive old standalone repos and drive Renovate replacements.
4. [x] OpenShift actions → `bcgov/actions-openshift`.

Internal workflows in `bcgov/actions` use GitHub's self-repository syntax (`uses: $/action-name`) for sibling actions and reusable workflows at the running commit. Downstream consumers continue to pin `bcgov/actions/<name>@vX.Y.Z`.
