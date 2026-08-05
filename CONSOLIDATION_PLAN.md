# Consolidate GitHub Actions into Two Repositories

## Overview

This plan consolidates scattered bcgov GitHub Actions into two centralized repositories:

- **bcgov/actions** (current repo): For non-OpenShift/general actions
- **bcgov/actions-openshift** (new repo): For OpenShift-specific actions

Each action will live in its own subdirectory within the appropriate repository.

## Versioning Strategy

All actions in each repository are versioned and released together as a **single suite**. A single semver tag (e.g. `v1.2.3`) on the repository applies to every action simultaneously.

> **Consumers must never pin to `@main`.** README examples use `@vX.Y.Z` — a placeholder that will not resolve — to force consumers to look up the [latest release](../../releases) and pick a real version or SHA.

## Repository Structure

### bcgov/actions (General Actions - Current Repo)

```
actions/
├── actionlint/
├── builder-ghcr/
├── diff-triggers/
├── get-pr/
├── image-tracker/
├── pr-description-add/
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
- [ ] Create `bcgov/actions-openshift`
- [x] Establish repository structure and documentation standards

**Phase 2: Migration with Backwards Compatibility**
1. Migrate each action to its new location.
2. Add **::warning::** deprecation notices to the old action repositories. *(Note: We initially planned to use thin wrapper actions to call the new locations, but this caused logging problems, so we only added deprecation warnings.)*

**Phase 3: Update Workflows & Deprecation**
1. Update internal workflows to use new locations.
2. Set deprecation timeline for old repos (e.g., 6 months).
3. Archive old repos after migration.
