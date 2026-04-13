# Image Tracker (Forensic History Traversal)

Resolve stable image SHAs from GitHub Container Registry (GHCR) by traversing the git history.

## The Problem
CI builds often create images on every commit to `main`, but humans (or bots) create **Tags** and **Releases** at a later point in time. Often, the commit that is tagged (e.g., a "version bump" or "merge commit") **is not the commit that actually built the image**. This creates an "Artifact Gap" where the release tag doesn't have a corresponding image in GHCR.

## The Solution: Forensic Walking
Image Tracker solves this by taking a starting **Revision** (Tag, Branch, or SHA) and "walking" backwards through its ancestry. It checks each commit for a corresponding `sha-<sha>` image in GHCR until it finds a match for all requested packages.

This ensures you always get the **exact binary state** that leads to a release, even if the release commit itself didn't trigger a build.

## Usage

```yaml
- name: Resolve Images
  id: tracker
  uses: bcgov/actions/image-tracker@main
  with:
    package: 'frontend, backend, database'
    revision: 'v1.2.3' # Optional: Walk back from this tag (Defaults to HEAD)
    max_depth: 50      # Optional: How many commits to walk (Defaults to 100)
```

## Inputs

| Input | Description | Default |
|---|---|---|
| `package` | **Required.** One or more package names (comma separated). | - |
| `revision` | The Tag, Branch, or SHA to start the walk from. | `HEAD` |
| `max_depth` | How many commits to traverse before failing. | `100` |
| `token` | GitHub token for PR metadata lookups (to support squash merges). | `github.token` |
| `repository` | The repository to resolve against. | `current` |

## Outputs

| Output | Description |
|---|---|
| `bundle` | A JSON object mapping package names to SHAs: `{"frontend":"sha-abc123"}` |

## Internal Logic: PR Mapping
To support **Squash Merges**, Image Tracker doesn't just check the commit SHA. It also uses the GitHub API to find the **PR Head SHA** associated with any merge commit. It checks the PR's original head commit FIRST, ensuring that squashed artifacts are correctly resolved.
