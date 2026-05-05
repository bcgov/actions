# Image Tracker (Forensic History Traversal)

Resolve stable image SHAs from GitHub Container Registry (GHCR) by traversing the git history.

## Requirements

**This action requires images to be published with [`docker/metadata-action`](https://github.com/docker/metadata-action) using its default `type=sha` tag.** That means tags of the form `sha-<7-char-short-sha>` (e.g. `sha-abc1234`). No other tag formats are supported.

A minimal publishing workflow looks like:

````yaml
- uses: docker/metadata-action@v5
  id: meta
  with:
    images: ghcr.io/${{ github.repository }}
    # Default `tags:` is sufficient — it emits `type=sha` (short) on every push.

- uses: docker/build-push-action@v6
  with:
    push: true
    tags: ${{ steps.meta.outputs.tags }}
````

If you publish with any other tag format (full SHA, semver-only, etc.), Image Tracker will not find your images.

## The Problem
CI builds often create images on every commit to `main`, but humans (or bots) create **Tags** and **Releases** at a later point in time. Often, the commit that is tagged (e.g., a "version bump" or "merge commit") **is not the commit that actually built the image**. This creates an "Artifact Gap" where the release tag doesn't have a corresponding image in GHCR.

## The Solution: Forensic Walking
Image Tracker solves this by taking a starting **Revision** (Tag, Branch, or SHA) and "walking" backwards through its ancestry. It checks each commit for a corresponding `sha-<short-sha>` image in GHCR until it finds a match for all requested packages.

This ensures you always get the **exact binary state** that leads to a release, even if the release commit itself didn't trigger a build.

## Usage

````yaml
- name: Resolve Images
  id: tracker
  uses: bcgov/actions/image-tracker@main
  with:
    package: 'frontend, backend, database'
    revision: 'v1.2.3' # Optional: Walk back from this tag (Defaults to HEAD)
    max_depth: 50      # Optional: How many commits to walk (Defaults to 100)
````

## Inputs

| Input        | Description                                                       | Default       |
| ------------ | ----------------------------------------------------------------- | ------------- |
| `package`    | **Required.** One or more package names (comma separated).        | -             |
| `revision`   | The Tag, Branch, or SHA to start the walk from.                   | `HEAD`        |
| `max_depth`  | How many commits to traverse before failing.                      | `100`         |
| `token`      | GitHub token for PR metadata lookups (to support squash merges).  | `github.token`|
| `repository` | The repository to resolve against.                                | current repo  |
| `dir`        | Directory containing the git repository.                          | `.`           |

## Outputs

| Output     | Description                                                                                 |
| ---------- | ------------------------------------------------------------------------------------------- |
| `packages` | JSON object mapping package names to resolved short-SHA tags: `{"frontend":"sha-abc1234"}`. |
| `bundle`   | Alias for `packages` (identical value).                                                     |

## Internal Logic: PR Mapping
To support **Squash Merges**, Image Tracker doesn't just check the commit SHA. It also uses the GitHub API to find the **PR Head SHA** associated with any merge commit. It checks the PR's original head commit FIRST, ensuring that squashed artifacts are correctly resolved.
