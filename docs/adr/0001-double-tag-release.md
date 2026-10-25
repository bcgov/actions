# ADR 0001: Double-tag releases

## Status

Accepted

## Context

`test-and-analyse` runs an ncc bundle in `dist/`. `dist/` is git-ignored and must never land on `main`, but consumers (and Renovate) need a tag that contains it. The old flow deleted and recreated a published release and its tag, so the tag briefly did not resolve.

## Decision

1. A maintainer publishes release `vX.Y.Z` from the GitHub Releases page, targeting the tip of `main`. Nobody pushes release tags by hand. The workflow rejects a release that is not on the `main` tip or not `vX.Y.Z`.
2. `.github/workflows/release.yml` runs on `release: published`. It tags the release commit `vX.Y.Z-src`, builds `dist/` on a side commit, moves `vX.Y.Z` to that commit, and regenerates the notes `-src` to `-src` (`previous_tag_name` is the newest earlier `v*-src`; the first double-tag release starts from the last `v*` tag).
3. `-src` tags are kept permanently; they mark the `main` commit each release was built from.

`dist/` only exists on the side commit, which no branch points to. No long-lived release branches. No merge queues. This repo has no tag ruleset; tag protection is procedural.

## Consequences

- The human step stays the Releases page; the double tag is hidden in automation.
- `vX.Y.Z` briefly points at the `main` commit without `dist/` until the run finishes, so a pin or Renovate PR made in that window can need a re-run.
- A failed run leaves `vX.Y.Z` without `dist/` (and possibly `vX.Y.Z-src`). Fix the cause and publish the next patch version.
- Pins and Renovate use `vX.Y.Z`, never `-src`.
