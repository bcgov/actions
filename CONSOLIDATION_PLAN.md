# Consolidate GitHub Actions into Two Repositories

## Overview

This plan consolidates scattered bcgov GitHub Actions into two centralized repositories:

- **bcgov/actions** (current repo): For non-OpenShift/general actions
- **bcgov/actions-openshift** (new repo): For OpenShift-specific actions

Each action will live in its own subdirectory within the appropriate repository.

## Repository Structure

### bcgov/actions (General Actions - Current Repo)

```
actions/
├── diff-triggers/
├── pr-description-add/
├── test-and-analyse/
├── get-pr/
├── builder-ghcr/
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
2. Update old action repositories to be **thin wrapper actions** that:
   - Call the new consolidated action location.
   - Maintain the same interface/inputs.
   - Add **::warning::** deprecation notices.

**Phase 3: Update Workflows & Deprecation**
1. Update internal workflows to use new locations.
2. Set deprecation timeline for old repos (e.g., 6 months).
3. Archive old repos after migration.
