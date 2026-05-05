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
| `max_depth` | How many commits to traverse before failing (in standard mode). | `100` |
| `inventory_depth` | If set, walks exactly this many commits and reports all found images (Audit Mode). | - |
| `token` | GitHub token for PR metadata lookups (to support squash merges). | `github.token` |
| `repository` | The repository to resolve against (e.g. `owner/repo`). | `current` |

## Outputs

| Output | Description |
|---|---|
| `tag` | The resolved SHA for the first (or only) package. (e.g. `sha-abc123`). |
| `bundle` | A JSON object mapping package names to SHAs: `{"frontend":"sha-abc123"}` |
| `inventory` | A JSON list of all images found during an `inventory_depth` walk. |

## Internal Logic: PR Mapping
To support **Squash Merges**, Image Tracker doesn't just check the commit SHA. It also uses the GitHub API to find the **PR Head SHA** associated with any merge commit. It checks the PR's original head commit FIRST, ensuring that squashed artifacts are correctly resolved.

### Forensic Previews (Open PRs)
The tracker also fetches **Open PRs**. This is critical for CI/CD pipelines triggered by `pull_request` events, where the `HEAD` is often a transient merge commit that hasn't been built. The tracker maps this merge commit back to the PR's head branch to find the actual container image.

## Audit Mode (Inventory)
Setting `inventory_depth` enables **Audit Mode**. Instead of stopping at the first match, the tracker walks a fixed "Search Budget" of commits and generates a report of every resolvable image it finds. 

This is useful for:
*   **Troubleshooting**: Finding exactly when an image went missing.
*   **Rollback Selection**: Getting a menu of stable versions to choose from.
*   **History Visibility**: Seeing the merge dates and PR associations for your artifact lineage.
