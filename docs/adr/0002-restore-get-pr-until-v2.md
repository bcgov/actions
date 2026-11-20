# ADR 0002: Restore get-pr until v2.0.0

## Status

Accepted

## Context

`get-pr` was migrated from `bcgov/action-get-pr` (#64), removed in favour of `image-tracker` (#202), restored as a drop-in (#290), had its `github_token` input renamed to `token` (#300), and was removed again in v0.11.0 (#316). `image-tracker` without `packages` now resolves only the PR number (#367).

`bcgov/action-get-pr` has about 152 dependent repositories. Moving each of them to `image-tracker` means rewriting their steps, and `image-tracker` is a larger action whose PR lookup was, until #367, a slow by-product of a registry scan. Those callers need a path that changes nothing but the `uses:` line.

## Decision

1. Restore `get-pr/` from the last commit before #316 (`ceeaad1` #290 plus `88b90e3` #300), not a wrapper around `image-tracker`. That code has already run in this suite.
2. Keep the `bcgov/action-get-pr` v0.3.1 interface: `debug`, `github_token` and output `pr`. `token` stays, and `github_token`, when set, is used instead of it. `debug` is read by `get-pr` itself, because the shared input helper no longer reads a `debug` input.
3. Run the shared input check, like the suite's other Node actions, so undeclared inputs fail.
4. `get-pr` is deprecated. Its README points to `image-tracker`. It gets no new features and is removed in `v2.0.0`.

## Consequences

- Callers of `bcgov/action-get-pr` can move to `bcgov/actions/get-pr` by changing only `uses:`.
- The suite carries two PR-number lookups (`get-pr/index.js` and `shared/pr-number.js`) until `v2.0.0`; fixes go to `image-tracker`.
- `github_token` breaks this repo's single-name input rule for one action, only until `v2.0.0`.
- Removing `get-pr` in `v2.0.0` is a breaking change for any caller still on it; release notes before then should point to `image-tracker`.
