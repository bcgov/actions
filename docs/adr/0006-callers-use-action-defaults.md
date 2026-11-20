# ADR 0006: Callers use action defaults and omit redundant inputs

## Status

Accepted

## Context

Caller workflows frequently copy-paste every documented input (`debug: false`, `dry_run: false`, `labels: ""`, or explicit default branches/paths). When an action evolves—for example changing a default, retiring an unused input, or enforcing declared inputs strictly via `input-enforcer`—redundant inputs in downstream repositories either cause immediate workflow failures or silently pin callers to stale choices.

## Decision

1. Caller workflows should rely on each action's declared defaults and omit inputs whose value matches the action default.
2. Actions enforce strict schemas via `input-enforcer` and [shared/inputs.js](../../shared/inputs.js): undeclared or removed inputs fail fast instead of being ignored, and inputs have one canonical name (no silent alias cascades, aside from temporary deprecation bridges like [ADR 0002](0002-restore-get-pr-until-v2.md)).

## Consequences

- Downstream workflow files stay concise and automatically inherit safe defaults and improvements on suite upgrades.
- Removing or renaming an input in `bcgov/actions` is a breaking change for any caller passing it explicitly and requires a SemVer major/pre-1.0 minor bump and release note.
