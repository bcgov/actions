# ADR 0001: Double-tag releases

## Status

Accepted

## Context

`test-and-analyse` runs an ncc bundle in `dist/`. `dist/` is git-ignored and must never land on `main`, but consumers (and Renovate) need a tag that contains it. The old flow deleted and recreated a published release and its tag, so the tag briefly did not resolve.

## Decision

1. Cut `vX.Y.Z-src` on the tip of `main` and push it. The workflow rejects a tag that is not the `main` tip.
2. `.github/workflows/release.yml` runs on that tag. It builds `dist/` on a side commit off the `-src` tag, tags that commit `vX.Y.Z`, and publishes the `vX.Y.Z` release. Release notes compare `-src` to `-src`: they start from the newest earlier `v*-src` tag whose `vX.Y.Z` release exists (the first double-tag release starts from the last `v*` tag, since no `-src` tag exists yet).
3. `-src` tags are kept permanently; they mark the `main` commit each release was built from.

`dist/` only exists on the side commit, which no branch points to. No long-lived release branches. No merge queues.

## Consequences

- `vX.Y.Z` appears once, already containing `dist/`, so Renovate and pins never see a tag without it.
- A failed run leaves `vX.Y.Z-src` and no `vX.Y.Z`. Fix the cause and cut the next patch version's `-src` tag.
- Pins and Renovate use `vX.Y.Z`, never `-src`.
- Publishing a release from the Releases page no longer builds `dist/`.
