# ADR 0004: Image promotion by digest (`build -> image-tracker -> deploy`)

## Status

Accepted

## Context

The legacy promotion pattern resolved a pull request number (`get-pr`), tagged images with mutable `:<pr>` tags, and retagged them to `:test` or `:prod`. On squash merges, `HEAD` on `main` is a new commit that was never built in a PR, and mutable tags hide which exact artifact was deployed or rebuilt.

## Decision

1. Promote container images along `build -> image-tracker -> deploy` using immutable OCI digests (`steps.tracker.outputs.digest` / `images`), never mutable `:<pr>` or environment tags as the deployment identity.
2. `image-tracker` matches OCI `org.opencontainers.image.revision` labels against git commit ancestry.
   - A hit resolves the immutable digest (even if built on an earlier commit for an unchanged package).
   - A miss exits non-zero (`exit 1`). Workflows must not silently skip empty digests or bypass missing images on forks.
3. Merge and promotion workflows must set `max_depth` high enough (for example `100`, the default) to walk past squash-merge commits and unchanged-package commits to the most recent built image for each package. `max_depth: 1` only answers whether the exact current SHA was built.
4. `get-pr` remains deprecated only as a migration bridge until `v2.0.0` ([ADR 0002](0002-restore-get-pr-until-v2.md)); new workflows use `image-tracker`.

## Consequences

- Every deployment is tied to an immutable image digest and traceable git revision.
- Unbuilt commits (such as merged external forks that skipped registry push) fail fast rather than deploying stale or missing tags and are resolved by triggering a same-repo build.
