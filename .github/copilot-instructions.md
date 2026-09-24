# Release ncc bundles (local)

`pr-description-add/dist/` and `test-and-analyse/dist/` are committed only by `.github/workflows/release.yml`.

- Trigger: `release` / `published` on `bcgov/actions`. Do not run it on `pull_request` or `push` to `main`. Do not require a draft release.
- Checkout `github.event.release.tag_name`. Exit 0 when `github.actor` is `github-actions[bot]`, or when `HEAD` subject is `chore(dist): rebuild ncc bundles for release`.
- Otherwise `gh release delete <tag> --yes --cleanup-tag` before `npm ci`. A failed job leaves that tag deleted. Do not delete any other tag.
- Then `npm ci` and `npm run build`. When `pr-description-add/dist/` or `test-and-analyse/dist/` differ, commit that subject and create the tag on the new commit. When they match, create the tag on the original commit. `gh release create` keeps the saved title, notes, and prerelease flag. Do not push `main`. Do not commit `dist/` on pull requests.
- Consumers pin the tag, or that tag's SHA after this workflow succeeds. `@main` does not contain the rebuild. `uses: $/…` in this repo loads the workflow commit, not a workspace ncc overwrite.

# Image promotion (local)

`build → image-tracker → deploy` by digest. Spec: `image-tracker/README.md`. Do **not** copy `quickstart-openshift` `merge.yml` (still `get-pr` + `:<pr>` tags) as the image contract.

Merge/promote: walk (`max_depth` e.g. `100`). Miss = `exit 1`. No fork special case. No mutable PR tag as the image identity.
