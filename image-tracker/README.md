# Image Tracker

Resolve immutable GHCR image **digests** for a given git commit by reading the
`org.opencontainers.image.revision` OCI label embedded in each image's config.

## Permissions

To run this action, the calling workflow job must have the following minimum permissions:

```yaml
permissions:
  contents: read
  pull-requests: read
  packages: read
```


## How it works

Every OCI-compliant image has a config blob. Builds that use
[`docker/metadata-action`](https://github.com/docker/metadata-action) (or raw
`buildx --label`) embed standard OCI labels including
`org.opencontainers.image.revision` — the git commit SHA that produced the
image.

config, and returns the **manifest digest** (`sha256:...`) of the image whose
revision label matches your target commit. 

Tag names (`sha-<7>`, `pr-123`, `latest`, etc.) are used as search hints, but the **label is the sole authority**. Even if a tag matches your SHA, the tracker will verify the internal OCI label before returning the digest.

The returned digest is immutable and cryptographically verified on pull, making
it the recommended form for deployment references.

## Requirements

The target images **must** be built with OCI labels populated. The easiest way
is [`docker/metadata-action`](https://github.com/docker/metadata-action), which
sets the labels by default. At bcgov, the
[`bcgov/actions/builder-ghcr`](../builder-ghcr/)
wrapper does this for you when `metadata_tags: true` (the default from v4.3.0).

Images that lack the `org.opencontainers.image.revision` label cannot be
resolved — there is no workaround short of rebuilding them with proper labels.

## Usage

```yaml
- name: Resolve image for HEAD
  id: tracker
  uses: bcgov/actions/image-tracker@vX.Y.Z
  with:
    package: frontend

- name: Deploy
  run: ./deploy.sh ${{ steps.tracker.outputs.digest }}
```

Multiple packages:

```yaml
- id: tracker
  uses: bcgov/actions/image-tracker@vX.Y.Z
  with:
    package: frontend, backend, migrations

- run: |
    echo "frontend: $(echo '${{ steps.tracker.outputs.images }}' | jq -r '.frontend')"
```

Resolve a non-HEAD revision (tag, branch, or SHA):

```yaml
- uses: bcgov/actions/image-tracker@vX.Y.Z
  with:
    package: frontend
    revision: v1.2.3
```

External repository:

```yaml
- uses: actions/checkout@v6
  with:
    repository: bcgov/some-other-repo
    path: target
    fetch-depth: 0

- uses: bcgov/actions/image-tracker@vX.Y.Z
  with:
    package: frontend
    repository: bcgov/some-other-repo
    dir: target
```

## Inputs

| Input        | Required | Default              | Description                                                                    |
| ------------ | -------- | -------------------- | ------------------------------------------------------------------------------ |
| `package`    | ✔        | —                    | One or more package names (comma/space/newline separated).                     |
| `revision`   |          | `HEAD`               | Git revision (SHA, branch, or tag) to resolve against.                         |
| `repository` |          | current repo         | Repository owning the images.                                                  |
| `dir`        |          | `.`                  | Working directory containing the git repository.                               |
| `github_token` |        | `github.token`       | GitHub token used to mint a GHCR bearer token.                                 |
| `max_tags`   |          | `500`                | Upper bound on tags inspected per package before failing.                      |
| `max_depth`  |          | `1`                  | Max number of commits back in history to search for an image.                  |

Package-to-image-path convention:
- If package name == repository name → `ghcr.io/<owner>/<repo>`
- Otherwise → `ghcr.io/<owner>/<repo>/<package>`

## Outputs

| Output    | Description                                                                                       |
| --------- | ------------------------------------------------------------------------------------------------- |
| `images`  | JSON object: `{"<pkg>": "ghcr.io/<owner>/<repo>/<pkg>@sha256:..."}`. Fully pullable references.   |
| `digests` | JSON object: `{"<pkg>": "sha256:..."}`. Bare digests only.                                        |
| `image`   | Convenience — the fully-qualified digest reference for the first package. Empty on failure.       |
| `digest`  | Convenience — the bare digest for the first package. Empty on failure.                            |

Using a digest in a Dockerfile:

```dockerfile
FROM ghcr.io/owner/repo@sha256:3fa4...
```

Or via the action's output directly:

```yaml
- run: docker pull ${{ steps.tracker.outputs.image }}
```

## Why digests, not tags?

Tags are mutable — anyone with push access can move them. Digests are content
addresses — they are computed from the image bytes and cannot point to
anything else. Using digests for deployment references gives you:

- **Reproducibility** — the same commit always yields the same digest.
- **Tamper evidence** — Docker/containerd validate the pulled layers hash up
  to the digest on pull.
- **Format independence** — the tagging scheme the publisher uses (or
  changes) never breaks your resolution.
