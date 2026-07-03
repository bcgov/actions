# bcgov/actions (Shared GitHub Actions)

A centralized repository for custom GitHub Actions used across the `bcgov` organization. 

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
- **Uses:** `bcgov/actions/workflow-notifier@main`

### [image-tracker](./image-tracker/)
Forensic history traversal to resolve stable image SHAs from Tags or SHAs.
- **Uses:** `bcgov/actions/image-tracker@main`

### [diff-triggers](./diff-triggers/)
Checks git diff for file and path changes to conditionally trigger workflow jobs.
- **Uses:** `bcgov/actions/diff-triggers@main`

### [builder-ghcr](./builder-ghcr/)
Generic GHCR container builder with automatic tag management.
- **Uses:** `bcgov/actions/builder-ghcr@main`

### [get-pr](./get-pr/)
Resolve the Pull Request number for merge queues, squash merges, pushes, and releases.
- **Uses:** `bcgov/actions/get-pr@main`

### [test-and-analyse](./test-and-analyse/)
Universal Test and Analyze with Triggers, SonarCloud, and Multi-Language Support.
- **Uses:** `bcgov/actions/test-and-analyse@main`

---

## ✨ Standards & Principles

1. **Standard Inputs**: All actions SHOULD support `github_token` and `debug` inputs.
2. **Node-First**: Prefer **Node.js Actions** (v24 with ESLint and Vitest) to ensure type safety, robust test coverage, and secure API integration.
3. **Consistent Branding**: Icons/Colors should reflect purpose (Build = blue, Fail/Alert = red).
