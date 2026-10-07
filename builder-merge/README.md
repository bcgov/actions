# Builder Merge

Publishes a multi-architecture tag on GitHub Container Registry (`ghcr.io`) from [`builder`](../builder/)'s canonical amd64 image and its per-architecture images (e.g. `-arm64`), so one tag runs natively on any machine.

It only writes **separate** tags (`:<pr>-multiarch`, `:<sha>-multiarch`). The canonical tags stay amd64, so OpenShift deploys and `image-tracker` are unaffected, and if this action fails, nothing that deploys is affected.

## Permissions

`packages: write`, to push the merged tags.

## Usage

```yaml
jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - uses: bcgov/actions/builder@vX.Y.Z
        with:
          package: backend

  build-arm64:
    runs-on: ubuntu-24.04-arm
    steps:
      - uses: bcgov/actions/builder@vX.Y.Z
        with:
          package: backend
          architecture: arm64

  merge:
    needs: [build, build-arm64]
    runs-on: ubuntu-24.04
    permissions:
      packages: write
    steps:
      - uses: bcgov/actions/builder-merge@vX.Y.Z
        with:
          package: backend
```

Developers then pull `ghcr.io/<owner>/<repo>/backend:<pr>-multiarch` on any architecture.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `package` | required | Package name, as passed to `builder` |
| `tags` | PR number | Tags passed to `builder`. The source commit SHA is always added |
| `architectures` | `arm64` | Architectures built with `builder`'s `architecture` input, comma-separated. The canonical amd64 image is always included |
| `tag_suffix` | `-multiarch` | Suffix for the published tags. Must be non-empty, so canonical tags are never overwritten |
| `source_sha` | PR head SHA or `github.sha` | Only needed for builds from an external `repository`; pass `builder`'s `source_sha` output |
| `token` | `github.token` | Registry token |
| `username` | `github.actor` | Registry username |

## Outputs

| Output | Description |
| --- | --- |
| `digest` | Digest of the multi-arch index |
| `image_path` | `/owner/repo/package:<tag>-multiarch`, as for `builder` |

## Behaviour

- Image names, tags and fork handling come from `builder`'s own helpers, so they always match what `builder` pushed.
- A missing image fails the step, naming the tag it expected.
- Fork pull requests can't push to GHCR, so `builder` only validated the builds; `builder-merge` skips with a notice and empty outputs.
