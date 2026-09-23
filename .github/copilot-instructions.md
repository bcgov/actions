# Release ncc bundles (local)

`pr-description-add/dist/` and `test-and-analyse/dist/` are committed only by `.github/workflows/release.yml`.

- Trigger: `release` / `published` on `bcgov/actions`. Do not run it on `pull_request` or `push` to `main`.
- Checkout `github.event.release.tag_name`. `npm ci` then `npm run build`. Exit 0 when those two dist trees already match, or when `HEAD` subject is `chore(dist): rebuild ncc bundles for release`.
- Otherwise commit that subject on branch `dist-${{ github.run_id }}`, force-push `refs/tags/<tag>` to that commit, `gh release edit <tag> --target <sha>`, delete the branch. Do not push `main`. Do not commit `dist/` on pull requests.
- Consumers pin the tag, or that tag's SHA after this workflow succeeds. `@main` does not contain the rebuild. `uses: $/…` in this repo loads the workflow commit, not a workspace ncc overwrite.

# Image promotion (local)

`build → image-tracker → deploy` by digest. Spec: `image-tracker/README.md`. Do **not** copy `quickstart-openshift` `merge.yml` (still `get-pr` + `:<pr>` tags) as the image contract.

Merge/promote: walk (`max_depth` e.g. `100`). Miss = `exit 1`. No fork special case. No mutable PR tag as the image identity.
