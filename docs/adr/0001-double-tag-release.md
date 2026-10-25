# ADR 0001: Double-tag releases

## Status

Accepted

## Context

`test-and-analyse` runs an ncc bundle in `dist/`. `dist/` is git-ignored and must never land on `main`, but consumers (and Renovate) need a tag that contains it. The old flow deleted and recreated a published release and its tag, so the tag briefly did not resolve.

## Decision

1. Cut `vX.Y.Z-src` on the tip of `main` and push it.
2. `.github/workflows/release.yml` runs on that tag. It builds `dist/` on a side commit off the `-src` tag, tags that commit `vX.Y.Z`, and publishes the `vX.Y.Z` release. Release notes start from the last real `v*` tag, never a `-src` tag.
3. The workflow then deletes the `-src` tag.

`dist/` only exists on the side commit, which no branch points to. No long-lived release branches. No merge queues.

## Consequences

- `vX.Y.Z` appears once, already containing `dist/`, so Renovate and pins never see a tag without it.
- A failed run leaves `vX.Y.Z-src` in place and no `vX.Y.Z`. Fix `main`, delete the `-src` tag, and cut it again.
- Publishing a release from the Releases page no longer builds `dist/`.
