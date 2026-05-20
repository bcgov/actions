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
Resolve file-based change triggers for multi-package repositories.
- **Uses:** `bcgov/actions/diff-triggers@main`

### [builder-ghcr](./builder-ghcr/)
Generic GHCR container builder with automatic tag management.
- **Uses:** `bcgov/actions/builder-ghcr@main`

---

## 🛠 Scaffolding a New Action

Use the included scaffolding script to create a new action following our standards.

\`\`\`bash
# From the root of this repo:
chmod +x scaffold.sh
./scaffold.sh <action-name> "Optional description"
\`\`\`

This will:
1. Create a new directory.
2. Seed it with the standard \`action.yml\`.
3. Provide a base \`action.sh\` script.
4. Generate a starter \`README.md\`.

---

## ✨ Standards & Principles

1. **Standard Inputs**: All actions SHOULD support \`github_token\` and \`debug\` inputs.
2. **Bash-First**: Prefer **Composite Actions** calling dedicated shell scripts (\`action.sh\`) for simple logic.
3. **Consistent Branding**: Icons/Colors should reflect purpose (Build = blue, Fail/Alert = red).
