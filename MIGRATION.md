# Migration guide

Caller-facing changes from v0.9 to v1.0.0, one section per change. Each lists the action, before, after, why, and a copy-paste example. Error messages link to the matching section.

- [Triggers format](#triggers)
- [Finding affected callers](#finding-affected-callers)

## Triggers

**Actions:** `diff-triggers`, and every action that passes `triggers` on (`builder`, `test-and-analyse`, and actions-openshift `deployer`, `crunchy`, `oc-runner`). **Since:** v0.10.0.

**Before:** bash-style lists, which fail with `Invalid triggers input: ...`:

```yaml
triggers: ('backend/' 'frontend/')
```

**After:** one path per line (preferred), or a JSON array:

```yaml
triggers: |
  backend/
  frontend/
```

```yaml
triggers: '["backend/", "frontend/"]'
```

**Why:** `triggers` was parsed by guessing between several delimiters, so a quoting mistake could silently match nothing. One format per value, and the error shows your paths in the new format.

## Finding affected callers

Run this from your repository root to find bash-style trigger lists:

```bash
grep -rnE "triggers:\s*\(" .github/
```
