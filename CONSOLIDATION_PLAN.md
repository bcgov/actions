# Consolidate GitHub Actions into Two Repositories

## Overview

This plan consolidates scattered bcgov GitHub Actions into two centralized repositories:

- **bcgov/actions** (current repo): For non-OpenShift/general actions
- **bcgov/actions-openshift** (new repo): For OpenShift-specific actions

Each action will live in its own subdirectory within the appropriate repository.

**Status (2026-09):** The general suite in `bcgov/actions` is feature-complete for the
`v1.0.0` stabilization epic (#209): `builder/` (renamed from `builder-ghcr`),
`diff-triggers`, `image-tracker` (replaces standalone `get-pr` usage), and the other
actions listed below. Creating and migrating **`bcgov/actions-openshift`** is a later
sprint and is out of scope for the `v1.0.0` tag.

## Versioning Strategy

All actions in each repository are versioned and released together as a **single suite**. A single semver tag (e.g. `v1.2.3`) on the repository applies to every action simultaneously.

> **Consumers must never pin to `@main`.** README examples use `@vX.Y.Z` — a placeholder that will not resolve — to force consumers to look up the [latest release](../../releases) and pick a real version or SHA.

## Repository Structure

### bcgov/actions (General Actions - Current Repo)

```
actions/
├── builder/
├── diff-triggers/
├── image-tracker/
├── pr-description-add/
├── pr-validate/
├── sysdig-monitor/
├── test-and-analyse/
├── workflow-notifier/  # (Formerly report-failures)
├── README.md
└── LICENSE
```

### bcgov/actions-openshift (OpenShift Actions - New Repo)

```
actions-openshift/
├── crunchy/
├── oc-runner/
├── deployer-openshift/
├── postgres/
├── README.md
└── LICENSE
```

## Migration Strategy

**Phase 1: Assessment & Setup**
- [x] Create `bcgov/actions` (using current repo)
- [ ] Create `bcgov/actions-openshift` *(later sprint — not required for suite `v1.0.0`)*
- [x] Establish repository structure and documentation standards

**Phase 2: Migration with Backwards Compatibility** *(general suite)*
1. [x] Migrate general actions into `bcgov/actions` subdirectories (`builder/`, etc.).
2. [x] Add **::warning::** deprecation notices to the old standalone action repositories. *(Thin wrappers were abandoned due to logging problems.)*

**Phase 3: Update Workflows & Deprecation**
1. [x] Update internal suite workflows to sibling `uses: $/…` paths.
2. [ ] After `v1.0.0`: soak early adopters, then archive old standalone repos / drive Renovate replacements (#214 and follow-ons).
3. [ ] OpenShift actions → `bcgov/actions-openshift` (separate epic).

Internal workflows in `bcgov/actions` use GitHub's self-repository syntax (`uses: $/action-name`) for sibling actions and reusable workflows at the running commit. Downstream consumers continue to pin `bcgov/actions/<name>@vX.Y.Z`.
