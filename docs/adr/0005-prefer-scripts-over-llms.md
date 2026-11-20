# ADR 0005: Prefer scripts and actions over LLMs for expressible checks

## Status

Accepted

## Context

AI agents and LLM-backed review tools are sometimes proposed for repository checks, linting, or security gates in CI. Using an LLM for checks that can be expressed deterministically adds API key management, non-repeatable pass/fail outcomes, slower feedback loops, and recurring token cost for every downstream repository.

## Decision

1. Use deterministic scripts, GitHub Actions, linters, and scanners (such as `actionlint`, `shellcheck`, `input-enforcer`, Trivy, CodeQL, unit tests) for every CI policy, gate, and pull-request check that can be expressed as rules, patterns, or known commands.
2. Reserve LLMs for planning, triage, and interpreting non-deterministic failures—never as a required pass/fail CI gate for checks that a deterministic script can perform.

## Consequences

- Suite CI and downstream template workflows remain repeatable, auditable, fast, and runnable without LLM credentials or per-PR token spend.
- New checks added to `bcgov/actions` should ship as tested scripts or composite/Node actions with deterministic assertions.
