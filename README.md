# bcgov/actions (Shared GitHub Actions)

[![Issues](https://img.shields.io/github/issues/bcgov/actions)](/../../issues)
[![Pull Requests](https://img.shields.io/github/issues-pr/bcgov/actions)](/../../pulls)
[![Apache-2.0 License](https://img.shields.io/github/license/bcgov/actions.svg)](/LICENSE)
[![Lifecycle](https://img.shields.io/badge/Lifecycle-Experimental-339999)](https://github.com/bcgov/repomountie/blob/master/doc/lifecycle-badges.md)

A centralized repository for custom GitHub Actions used across the `bcgov` organization. 

---

## 🔒 Version Pinning Policy

> **Never reference these actions with `@main`.** Always pin to a release tag (e.g. `@v1.2.3`) or, better yet, a full commit SHA.
>
> Usage examples in this repo intentionally use `@vX.Y.Z` — a placeholder that **will not resolve**. This is by design: copy-paste should fail until you look up the [latest release](../../releases) and pick a real version.
>
> All actions in this repository are versioned and released together as a single suite.

---

## 🧪 Testing & PR Guidelines

To maintain "Boss Level" consistency across all our actions, every PR should:
1. **Pass Linting**: All `.sh` files must pass `shellcheck`.
2. **Include Functional Tests**: Add or update a workflow in `.github/workflows/` that exercises the action (use `dry_run: true` where appropriate).
3. **Verify Outputs**: Don't just check if it "ran"—verify that the `outputs` are actually what you expect.

---

## 🏗 Sub-Actions

### [workflow-notifier](./workflow-notifier/)
Find `CODEOWNERS` and coordinate notifications (GitHub Issues) on job failures.
- **Uses:** `bcgov/actions/workflow-notifier@vX.Y.Z`

### [image-tracker](./image-tracker/)
Forensic history traversal to resolve stable image SHAs from Tags or SHAs.
- **Uses:** `bcgov/actions/image-tracker@vX.Y.Z`

### [diff-triggers](./diff-triggers/)
Checks git diff for file and path changes to conditionally trigger workflow jobs.
- **Uses:** `bcgov/actions/diff-triggers@vX.Y.Z`

### [builder-ghcr](./builder-ghcr/)
Generic GHCR container builder with automatic tag management.
- **Uses:** `bcgov/actions/builder-ghcr@vX.Y.Z`

### [get-pr](./get-pr/)
Resolve the Pull Request number for merge queues, squash merges, pushes, and releases.
- **Uses:** `bcgov/actions/get-pr@vX.Y.Z`

### [test-and-analyse](./test-and-analyse/)
Universal Test and Analyze with Triggers, SonarCloud, and Multi-Language Support.
- **Uses:** `bcgov/actions/test-and-analyse@vX.Y.Z`

### [test-and-analyse-java](./test-and-analyse-java/)
Run Java unit tests, can analyse with SonarCloud.
- **Uses:** `bcgov/actions/test-and-analyse-java@vX.Y.Z`

### [actionlint](./actionlint/)
Lint GitHub Actions workflow files with caching and rate-limit proof execution.
- **Uses:** `bcgov/actions/actionlint@vX.Y.Z`

---

## ✨ Standards & Principles

1. **Standard Inputs**: All actions SHOULD support `github_token` and `debug` inputs.
2. **Node-First**: Prefer **Node.js Actions** (v24 with ESLint and Vitest) to ensure type safety, robust test coverage, and secure API integration.
3. **Consistent Branding**: Icons/Colors should reflect purpose (Build = blue, Fail/Alert = red).
