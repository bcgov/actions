# Shared input parsing

`inputs.js` is how every action in this repo reads list, boolean, enum, debug and token inputs, so they behave the same everywhere. It isn't an action; nothing calls it with `uses:`.

| Kind | Accepted | Rejected |
|---|---|---|
| List | one item per line, or a single value | `a, b`, JSON arrays, bash `('a' 'b')`, `a b`, `a;b`. The error names the value and shows it one item per line. |
| Boolean | `true` / `false` (any case) | anything else |
| Enum | one of the listed values (any case) | anything else |
| Debug | a run re-run with debug logging (`RUNNER_DEBUG=1`); actions have no `debug` input | |
| Token | the `token` input, else `GITHUB_TOKEN` from the env | |

## How actions use it

GitHub downloads the whole repository for `uses: bcgov/actions/<action>@<sha>`, so `../shared/inputs.js` is always next to the action.

- Node actions: `require('../shared/inputs.js')`.
- Composite actions: pass the input through `env:` and call the CLI, which prints the parsed value or fails the step with the same annotation:

```yaml
- env:
    INPUT_PACKAGES: ${{ inputs.packages }}
  run: node "$GITHUB_ACTION_PATH/../shared/inputs.js" list packages
```

CLI commands: `list <name>`, `bool <name> [default]`, `enum <name> <a,b,c> <default>`, `debug`, `token`, `assert-known <action_dir>`.

## Unknown inputs

Actions accept only the inputs declared in their `action.yml`. GitHub on its own only warns on any other `with:` key and keeps going; every action here fails instead, naming the bad key(s), listing the declared inputs and linking the action README. The check reads nothing but `action.yml` and the keys passed, so it needs no per-action setup.

test-and-analyse no longer checks out code (`repository`, `branch`, `checkout_path` are gone): run `actions/checkout` yourself and point `working_directory` at it.

- Node actions call `assertKnownActionInputs(__dirname)` first. The runner sets `INPUT_<NAME>` for every `with:` key, declared or not, and the check compares those against `action.yml`.
- Composite actions run it as their first step. Their own steps set `INPUT_*` vars, so they pass `${{ toJSON(inputs) }}`, which also holds undeclared keys:

```yaml
- name: Check inputs
  shell: bash
  env:
    INPUTS_JSON: ${{ toJSON(inputs) }}
  run: node "$GITHUB_ACTION_PATH/../shared/inputs.js" assert-known "$GITHUB_ACTION_PATH"
```

Composite keys (`INPUTS_JSON`) compare case-insensitively as written; only node `INPUT_*` env names map spaces to `_`. bcgov/actions-openshift copies this check; this repo is the source of truth.

- `pr-description.js`: append markdown to a PR description once (pr-description-add, pr-validate `markdown`). Resolves the PR from the `pr` input or the event, so it works outside `pull_request`.
