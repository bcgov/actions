# Builder Merge

Merges per-architecture images from [`builder`](../builder/) into one multi-architecture tag on GitHub Container Registry (`ghcr.io`).

Use it to build images natively for each architecture, with no QEMU emulation: run `builder` once per architecture on a matching runner with a `tag_suffix`, then run `builder-merge` once those builds finish.

## Permissions

`packages: write`, to push the merged tags.

## Usage

```yaml
jobs:
  build:
    strategy:
      matrix:
        include:
          - runner: ubuntu-24.04
            arch: amd64
          - runner: ubuntu-24.04-arm
            arch: arm64
    runs-on: ${{ matrix.runner }}
    permissions:
      contents: read
      packages: write
    steps:
      - uses: bcgov/actions/builder@vX.Y.Z
        with:
          package: backend
          tag_suffix: -${{ matrix.arch }}
          tag_fallback: test
          triggers: |
            backend/

  merge:
    needs: build
    runs-on: ubuntu-24.04
    permissions:
      packages: write
    outputs:
      digest: ${{ steps.merge.outputs.digest }}
    steps:
      - id: merge
        uses: bcgov/actions/builder-merge@vX.Y.Z
        with:
          package: backend
```

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `package` | required | Package name, as passed to `builder` |
| `tags` | PR number | Tags for the multi-arch image, as passed to `builder` (without the suffix). The source commit SHA is always added |
| `tag_suffixes` | `-amd64` and `-arm64` | Each architecture's `builder` `tag_suffix`, one per line |
| `source_sha` | PR head SHA or `github.sha` | Only needed for builds from an external `repository`; pass `builder`'s `source_sha` output |
| `token` | `github.token` | Registry token |
| `username` | `github.actor` | Registry username |

## Outputs

| Output | Description |
| --- | --- |
| `digest` | Digest of the multi-arch index. Deploy with this; each machine pulls its own architecture |
| `image_path` | `/owner/repo/package:tag` of the multi-arch image, as for `builder` |

## Behaviour

- Image names, tags and fork handling come from `builder`'s own helpers, so they always match what `builder` pushed.
- The plain tags (`<pr>`, `<sha>`) become one multi-arch index of every architecture's image. The `-amd64` / `-arm64` tags stay in the registry.
- When nothing triggered, every architecture retagged the same `tag_fallback` image, so it's kept as is with the same digest.
- A missing architecture image fails the step, naming the expected tag.
- Fork pull requests can't push to GHCR, so `builder` only validated the builds; `builder-merge` skips with a notice and empty outputs.
- `image-tracker` resolves multi-arch indexes through the amd64 image's revision label, so it works unchanged.
