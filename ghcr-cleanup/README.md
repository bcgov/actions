# GHCR Cleanup

Opt-in cleanup of this repository's GHCR package versions: deletes images left
by closed pull requests and untagged versions nothing references. Nothing runs
unless a workflow calls the action, and it only deletes with `dry_run: false`.

## Rules

A version is **kept** when any of these hold:

- It has a tag that is not a pull request tag: `prod`, `test`, `latest`,
  release tags, `buildcache`, or a commit SHA that is not one of a closed pull
  request's commits (such as a merge SHA tagged at promotion).
- It has a tag for an **open** pull request (`<n>` or `pr-<n>`).
- Its digest is listed in `keep_digests`.
- It is a child manifest (per-architecture image or attestation) of a kept
  multi-arch index, or a referrer (`subject`) of a kept image.

A version is **deleted** when none of the above hold and either:

- Every tag belongs to a **closed** pull request: `<n>` / `pr-<n>` for a closed
  pull request, or a full commit SHA from a closed pull request's commits (the
  SHA tag builder adds to every image, including older pushes to that pull
  request).
- It has no tags.

A numeric tag that is not a pull request number keeps the version. Commits
dropped from a pull request by a force-push, or past the API's first 250
commits of a pull request, are not known to belong to it, so their images are
kept.

### Deployed digests

`image-tracker` does not store deployed digests anywhere. It resolves a digest
from a commit's OCI revision label and returns it (`digest`, `digests`), and
only writes tags when its `tags` input is set. A deployed digest is protected
only when it carries a non-PR tag (for example `prod`, a release tag, `latest`,
or the merge SHA) or is passed in `keep_digests`. If you deploy a pull
request's image by digest without tagging it, pass that digest, or the closed
pull request's image is deleted.

## Behaviour

- `dry_run` defaults to `true`: every version is logged with its decision and
  nothing is deleted.
- Logs show package names, version IDs, tags, digests and reasons only.
- A package that does not exist is skipped with a log line.
- A package linked to a different repository, or to none, fails with nothing
  deleted from it. The packages API is owner-scoped, so this check keeps the
  action on this repository's packages.
- With `dry_run: false`, tags are read again just before deleting, and a
  version that became protected in the meantime (for example promoted to
  `prod`) is skipped. To also close the gap between that check and the delete,
  share a `concurrency` group with the workflows that publish, tag or promote
  these packages (example below).
- A version that is already gone when deleted is logged and skipped.
- If any pull request lookup or manifest read fails for a package, nothing is
  deleted from that package and the step fails after the other packages.
- A failed delete fails the step after the remaining deletes are attempted.

## Usage

Run on pull request close, with the digests your environments run:

```yaml
on:
  pull_request:
    types: [closed]

permissions: {}

# Same group in the workflows that build, tag or promote these packages
concurrency:
  group: ghcr-${{ github.repository }}
  cancel-in-progress: false

jobs:
  cleanup:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      packages: write
      pull-requests: read
    steps:
      - uses: actions/checkout@v7
        with:
          ref: ${{ github.event.repository.default_branch }}
          fetch-depth: 0

      # The images the default branch deploys now
      - id: deployed
        uses: bcgov/actions/image-tracker@vX.Y.Z
        with:
          package: backend, frontend
          repository: ${{ github.repository }}
          max_depth: 100

      - uses: bcgov/actions/ghcr-cleanup@vX.Y.Z
        with:
          packages: backend, frontend
          keep_digests: ${{ join(fromJSON(steps.deployed.outputs.digests).*, ' ') }}
          dry_run: false
```

Run it with the default `dry_run: true` first and read the log.

## Permissions

```yaml
permissions:
  contents: read
  packages: write
  pull-requests: read
```

`packages: read` is enough for a dry run. Deleting with `github.token` needs
the repository to have the `admin` role on each package, which GitHub grants to
the repository whose workflow published the package. No organization owner or
admin rights are needed, and only this repository's packages are touched.

## Inputs

| Input          | Required | Default        | Description                                                                      |
| -------------- | -------- | -------------- | -------------------------------------------------------------------------------- |
| `packages`     | ✔        | —              | Package names in this repository (comma/space/newline separated).                |
| `dry_run`      |          | `true`         | `true` logs only. `false` deletes. Any other value fails.                        |
| `keep_digests` |          | —              | Deployed manifest digests (`sha256:...`) to keep, with their index children.     |
| `token`        |          | `github.token` | Token that can list and delete versions of this repository's packages.           |

Package names follow `image-tracker`: `ghcr.io/<owner>/<repo>/<package>`, or
`ghcr.io/<owner>/<repo>` when the package name matches the repository name.

## Outputs

| Output     | Description                                                                                              |
| ---------- | -------------------------------------------------------------------------------------------------------- |
| `selected` | JSON array of versions selected for deletion (deleted unless dry run): `package`, `id`, `digest`, `tags`. |
