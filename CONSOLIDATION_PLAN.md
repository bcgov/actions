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
│   ├── action.yml
│   ├── README.md
│   └── [scripts/]
├── pr-description-add/
│   ├── action.yml
│   ├── README.md
│   └── [scripts/]
├── test-and-analyse/
│   ├── action.yml
│   ├── README.md
│   └── [scripts/]
├── test-and-analyse-java/
│   ├── action.yml
│   ├── README.md
│   └── [scripts/]
├── get-pr/
│   ├── action.yml
│   ├── README.md
│   └── [scripts/]
├── builder-ghcr/
│   ├── action.yml
│   ├── README.md
│   └── [scripts/]
├── report-failures/  # NEW ACTION
│   ├── action.yml
│   ├── README.md
│   └── [scripts/]
├── README.md
└── LICENSE
```

### bcgov/actions-openshift (OpenShift Actions - New Repo)

```
actions-openshift/
├── crunchy/
│   ├── action.yml
│   ├── README.md
│   ├── charts/
│   └── scripts/
├── oc-runner/
│   ├── action.yml
│   ├── README.md
│   └── [scripts/]
├── deployer-openshift/
│   ├── action.yml
│   ├── README.md
│   └── [scripts/]
├── postgres/
│   ├── action.yml
│   ├── README.md
│   └── [scripts/]
├── deployer-helm/
│   ├── action.yml
│   ├── README.md
│   └── [scripts/]
├── README.md
└── LICENSE
```

## Action Subdirectory Structure

Each action subdirectory follows this pattern:

```
action-name/
├── action.yml          # Action metadata (required)
├── README.md          # Documentation with usage examples
├── entrypoint.sh      # Main script (if composite action)
├── scripts/           # Supporting scripts (optional)
│   └── helper.sh
├── package.json       # If Node.js action (optional)
└── dist/              # If compiled action (optional)
```

**Usage in workflows:**

```yaml
- uses: bcgov/actions/diff-triggers@v1.0.0
- uses: bcgov/actions-openshift/crunchy@v1.2.5
```

## Action Naming Convention

Since actions are in a repo named `actions` or `actions-openshift`, subdirectory names do NOT need the `action-` prefix:

- ✅ `diff-triggers/` (not `action-diff-triggers/`)
- ✅ `crunchy/` (not `action-crunchy/`)
- ✅ `report-failures/` (not `action-report-failures/`)

Usage: `bcgov/actions/diff-triggers@v1.0.0`

## Migration Strategy

**Phase 1: Assessment & Setup**

1. Assess each existing action to determine:
   - Active usage status
   - Code quality and maintenance state
   - Dependencies and requirements

2. Create the `bcgov/actions-openshift` repository
3. Establish repository structure and documentation standards

**Phase 2: Migration with Backwards Compatibility**

1. Migrate each action to its new location in the consolidated repo
2. Update old action repositories to be thin wrapper actions that:
   - Call the new consolidated action location
   - Maintain the same interface/inputs
   - Add deprecation notices in README

3. This allows gradual migration without breaking existing workflows

**Example wrapper structure:**

```yaml
# In old repo: bcgov/action-diff-triggers/action.yml
name: 'Diff Triggers (Deprecated)'
description: '⚠️ This action has moved to bcgov/actions/diff-triggers'
runs:
  using: composite
  steps:
    - uses: bcgov/actions/diff-triggers@main
      with:
        # Pass through all inputs
```

**Phase 3: Update Workflows & Deprecation**

1. Create migration guide for teams
2. Update internal workflows to use new locations
3. Set deprecation timeline for old repos (e.g., 6 months)
4. Archive old repos after migration period

## New Action: report-failures

Create `report-failures` in the general actions repository:

**Location:** `bcgov/actions/report-failures/`

**Features:**

- Creates GitHub Issues for deployment failures in test/prod zones
- Reads CODEOWNERS file to auto-assign issue maintainers
- Only runs on failure conditions
- Skips for PR deployments (failures visible in PR checks)

**Inputs:**

- `zone` (required): Environment zone (test/prod)
- `workflow_run_id` (optional): Override workflow run ID
- `title_template` (optional): Custom issue title template
- `body_template` (optional): Custom issue body template

**Outputs:**

- `issue_number`: Created issue number
- `issue_url`: URL to created issue

## Implementation Steps

1. **Create repository structure** in both repos
   - Add top-level README explaining the consolidation
   - Set up directory structure for actions
   - Add LICENSE files

2. **Migrate actions incrementally**
   - Start with most-used or simplest actions
   - Test each migration thoroughly
   - Create wrapper actions in old repos

3. **Create new report-failures action**
   - Extract the job logic from the provided workflow
   - Convert to reusable composite action
   - Add proper inputs/outputs
   - Write documentation and examples

4. **Create migration script**
   - Script to help teams update their workflows
   - Search and replace old action references with new ones

5. **Documentation & Communication**
   - Create migration guide
   - Update all action READMEs
   - Communicate changes to teams

## Decisions Made

1. **Repository naming**: Use `bcgov/actions` (current repo) for general actions, create new `bcgov/actions-openshift` for OpenShift actions
2. **Versioning strategy**: GitHub releases and tags (semantic versioning)
3. **Migration script**: Yes, create a script to help teams update their workflows
4. **Deprecation timeline**: Not set yet - to be determined based on migration progress

