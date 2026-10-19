# Migration guide

Caller-facing changes from v0.9 to v1.0.0, one section per change. Each lists the action, before, after, why, and a copy-paste example. Error messages link to the matching section. Changes to [bcgov/actions-openshift](https://github.com/bcgov/actions-openshift) are in [its migration guide](https://github.com/bcgov/actions-openshift/blob/main/MIGRATION.md); the shared rules (lists, booleans, `diff_base`, `debug`) are explained here.

Before v1.0.0, renames have no aliases: the old name fails, or GitHub warns `Unexpected input` and the new input keeps its default.

| Section | Actions | Since |
|---|---|---|
| [Triggers format](#triggers) | diff-triggers, builder, test-and-analyse | v0.10.0 |
| [List inputs](#list-inputs) | ghcr-cleanup, image-tracker, workflow-notifier | v1.0.0 |
| [Boolean and enum inputs](#boolean-and-enum-inputs) | all | v1.0.0 |
| [`diff_base` and `ref`](#diff_base) | diff-triggers, builder, test-and-analyse | v1.0.0 |
| [`packages`](#packages) | image-tracker | v1.0.0 |
| [`token`](#token) | get-pr | v1.0.0 |
| [`notify_codeowners`](#notify_codeowners) | workflow-notifier | v1.0.0 |
| [`require_sonar`](#require_sonar) | test-and-analyse | v1.0.0 |
| [`debug`](#debug) | all | v1.0.0 |
| [Outputs](#outputs) | workflow-notifier | v1.0.0 |
| [actions-openshift changes](#actions-openshift) | oc-runner, deployer, crunchy, cleanup-pr | v1.0.0 |
| [Finding affected callers](#finding-affected-callers) | | |

## Triggers

**Actions:** `diff-triggers`, and every action that passes `triggers` on (`builder`, `test-and-analyse`, and actions-openshift `deployer`, `crunchy`, `oc-runner`). **Since:** v0.10.0.

**Before:** bash-style lists, which fail with `Invalid triggers input: ...`:

```yaml
triggers: ('backend/' 'frontend/')
```

**After:** one path per line (preferred), a comma-separated line (v1.0.0), or a JSON array:

```yaml
triggers: |
  backend/
  frontend/
```

```yaml
triggers: '["backend/", "frontend/"]'
```

**Why:** `triggers` was parsed by guessing between several delimiters, so a quoting mistake could silently match nothing. One format per value, and the error shows your paths in the new format.

## List inputs

**Actions:** every list input: `triggers`, ghcr-cleanup `packages` and `keep_digests`, image-tracker `packages` and `tags`, workflow-notifier `labels`. **Since:** v1.0.0.

**Before:** each action split lists its own way; some accepted spaces, some only commas.

```yaml
packages: backend frontend
```

**After:** one item per line (preferred), `a, b` on one line, or a JSON array. Space and semicolon separated lines fail with `Invalid <input> input: ...` and the same before/after example.

```yaml
packages: |
  backend
  frontend
```

```yaml
packages: backend, frontend
```

**Why:** one parser ([shared/inputs.js](shared/inputs.js)) for every action, so a value that works in one works in all.

## Boolean and enum inputs

**Actions:** all. **Since:** v1.0.0.

**Before:** booleans were compared to the string `'true'`, so `yes` or a typo silently meant `false` (or, in some actions, anything but `false` meant `true`).

```yaml
dry_run: yes
```

**After:** `true` or `false` (any case). Anything else fails with `Invalid <input> input: ... Use true or false.` Enums such as `dep_scan` (`off|warn|error`) and `language` (`node|java|python`) fail with the accepted values.

```yaml
dry_run: true
```

**Why:** a mistyped switch should fail loudly, not quietly turn a scan or a deletion on or off.

## diff_base

**Actions:** `diff-triggers`, `builder`, `test-and-analyse`. **Since:** v1.0.0.

**Before:** `ref` was the base the triggers are diffed against, and test-and-analyse used `branch` for the ref to check out.

```yaml
- uses: bcgov/actions/diff-triggers@<sha> # v0.10.0
  with:
    triggers: backend/
    ref: main
```

**After:** `diff_base` is the diff base. `ref` keeps its actions/checkout meaning (the branch, tag or SHA to check out), so test-and-analyse `branch` is now `ref`.

```yaml
- uses: bcgov/actions/diff-triggers@<sha> # v1.0.0
  with:
    triggers: backend/
    diff_base: main
```

```yaml
- uses: bcgov/actions/test-and-analyse@<sha> # v1.0.0
  with:
    repository: bcgov/quickstart-openshift
    ref: main # was branch: main
```

**Why:** `ref` meant two different things. `diff_base` matches dorny/paths-filter's `base`; the prefix keeps it from reading as a base image or PR base.

## packages

**Action:** `image-tracker`. **Since:** v1.0.0.

**Before:**

```yaml
- uses: bcgov/actions/image-tracker@<sha> # v0.10.0
  with:
    package: backend frontend
```

**After:**

```yaml
- uses: bcgov/actions/image-tracker@<sha> # v1.0.0
  with:
    packages: backend, frontend
```

**Why:** it takes a list, and ghcr-cleanup already calls the same thing `packages`.

## token

**Action:** `get-pr`. **Since:** v1.0.0.

**Before:**

```yaml
- uses: bcgov/actions/get-pr@<sha> # v0.10.0
  with:
    github_token: ${{ secrets.GITHUB_TOKEN }}
```

**After:** `token`, like every other action. It defaults to `github.token`, so most callers can drop it.

```yaml
- uses: bcgov/actions/get-pr@<sha> # v1.0.0
```

**Why:** one name for the GitHub token across the suite.

## notify_codeowners

**Action:** `workflow-notifier`. **Since:** v1.0.0.

**Before:** `true`, `false` or `fallback`.

```yaml
notify_codeowners: true
```

**After:** `always`, `fallback` (default) or `never`. `true` and `false` fail with the accepted values.

```yaml
notify_codeowners: always # was true; false is now never
```

**Why:** it has three states, so it is an enum, not a boolean.

## require_sonar

**Action:** `test-and-analyse`. **Since:** v1.0.0.

**Before:**

```yaml
sonar_token: ${{ secrets.SONAR_TOKEN }}
require_sonar: true
```

**After:** `require_sonar` is removed. An empty `sonar_token` skips Sonar with a warning annotation.

```yaml
sonar_token: ${{ secrets.SONAR_TOKEN }}
```

**Why:** it duplicated "is `sonar_token` empty?", and requiring Sonar fails every fork PR, which never gets secrets.

## debug

**Actions:** all (actions-openshift `oc-runner` renames `verbose`). **Since:** v1.0.0.

**Before:** `debug` did nothing in builder, diff-triggers and test-and-analyse; oc-runner called it `verbose`.

```yaml
verbose: true
```

**After:** every action takes `debug: true|false`, and a run re-run with debug logging (`RUNNER_DEBUG=1`) turns it on too.

```yaml
debug: true
```

**Why:** one switch, named the same everywhere, that actually does something.

## Outputs

**Action:** `workflow-notifier`. **Since:** v1.0.0.

**Before:** `assignees` was a comma-separated string: `alice,bob`.

**After:** a JSON array: `["alice","bob"]`.

```yaml
- run: echo "First assignee: ${{ fromJSON(steps.notify.outputs.assignees)[0] }}"
```

**Why:** list outputs are JSON across the suite (diff-triggers `changes`, ghcr-cleanup `selected`). Booleans are `true`/`false`; single values such as image-tracker `digest` stay plain strings.

## actions-openshift

`oc-runner` (`verbose` → `debug`, `diff_branch` → `diff_base`, `login_attempts` removed), `deployer` (`ref` → `diff_base`, `login_attempts` removed), `crunchy` (`diff_branch` → `diff_base`, `db_*` outputs renamed) and `cleanup-pr` (lists) are covered in the [actions-openshift migration guide](https://github.com/bcgov/actions-openshift/blob/main/MIGRATION.md):

- [login_attempts](https://github.com/bcgov/actions-openshift/blob/main/MIGRATION.md#login_attempts)
- [crunchy outputs](https://github.com/bcgov/actions-openshift/blob/main/MIGRATION.md#crunchy-outputs)

## Finding affected callers

Run this from your repository root. Each match is a line to change; the section name follows `#`.

```bash
grep -rnE \
  -e 'triggers:\s*\(' \
  -e '^\s+(package|github_token|require_sonar|branch|verbose|diff_branch|login_attempts):' \
  -e '^\s+ref:' \
  -e 'notify_codeowners:\s*.?(true|false)' \
  -e 'outputs\.(assignees|db_(host|port|user|name|secret))' \
  .github/
```

`ref:` matches also hit actions/checkout, which keeps `ref`. Only change it on diff-triggers, builder, test-and-analyse and deployer, where it was the diff base.
