# ADR 0003: Monorepo consolidation of the action suite

## Status

Accepted

## Context

GitHub Actions and reusable workflows for `bcgov` were previously spread across dozens of standalone `bcgov/action-*` repositories. Every shared dependency bump, input-parsing fix, or security hardening change required separate pull requests, separate releases, and per-repository Renovate updates across consumers.

## Decision

1. Consolidate shared actions into two versioned monorepos:
   - `bcgov/actions` for general CI, container build, scanning, and workflow-coordination actions.
   - `bcgov/actions-openshift` for OpenShift-specific deployment, database, and certificate actions.
2. Version and release all actions in each repository together under one SemVer suite tag (`vX.Y.Z`). Consumers pin the release commit SHA (with `# vX.Y.Z`) and never `@main`.
3. Internal workflows inside each suite use self-repository references (`uses: $/...`) so pull requests test the running commit rather than an older released tag.
4. Legacy standalone `bcgov/action-*` repositories remain unarchived with deprecation notices until downstream consumers complete migration, after which they are archived rather than maintained in parallel.

## Consequences

- Shared helpers (`shared/inputs.js`, `input-enforcer`) and CI standards apply across all suite actions at once.
- A breaking change to any action requires a suite major bump (a minor bump while pre-1.0), unless compatibility is preserved through an explicit deprecation bridge such as [ADR 0002](0002-restore-get-pr-until-v2.md).
- `bcgov/actions` releases precede `bcgov/actions-openshift` pin bumps so OpenShift actions stay aligned on one `bcgov/actions` release SHA.
