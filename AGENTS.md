# AGENTS.md

Repository facts for automated coding assistants. Teams may edit or remove this file.

## Image promotion

Pipeline: build, then `image-tracker`, then deploy by digest (`outputs.digest` / `images`). Details: [image-tracker/README.md](image-tracker/README.md).

- Don't use `quickstart-openshift` `.github/workflows/merge.yml` as the image spec. It still promotes mutable `:<pr>` tags via `get-pr`.
- A squash merge `HEAD` was never built. Merge/promote must set `max_depth` high enough to find the last OCI-labeled image per package (e.g. `100`). `max_depth: 1` only asks "was this SHA built?"; it is not merge promotion.
- A miss is `exit 1`. Forks don't change that: no empty-digest skip, no fork `if:`.
- Don't reject a digest because it was built on a different PR (unchanged package).
- Don't add `get-pr` or retag-by-PR-number as the deploy identity.

## Release ncc bundles

`pr-description-add/dist/` and `test-and-analyse/dist/` are committed only by `.github/workflows/release.yml`.

- Trigger: `release` / `published` on `bcgov/actions`. Do not run it on `pull_request` or `push` to `main`. Do not require a draft release.
- Checkout `github.event.release.tag_name`. Exit 0 when `github.actor` is `github-actions[bot]`, or when `HEAD` subject is `chore(dist): rebuild ncc bundles for release`.
- Otherwise `gh release delete <tag> --yes --cleanup-tag` before `npm ci`. A failed job leaves that tag deleted. Do not delete any other tag.
- Then `npm ci` and `npm run build`. When `pr-description-add/dist/` or `test-and-analyse/dist/` differ, commit that subject and create the tag on the new commit. When they match, create the tag on the original commit. `gh release create` keeps the saved title, notes, and prerelease flag. Do not push `main`. Do not commit `dist/` on pull requests.
- Consumers pin the tag, or that tag's SHA after this workflow succeeds. `@main` does not contain the rebuild. `uses: $/…` in this repo loads the workflow commit, not a workspace ncc overwrite.

## README usage examples

- Usage examples in action READMEs show how `bcgov/quickstart-openshift` would call the action: its workflows (`pr-open.yml`, `pr-close.yml`, `merge.yml`, `scheduled.yml`), its packages (`backend`, `frontend`, `migrations`) and its job order. Add a separate example only when the quickstart shape does not fit. Never say quickstart uses an action it does not use; read its workflows first.
