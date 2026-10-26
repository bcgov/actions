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

CLI commands: `list <name>`, `bool <name> [default]`, `enum <name> <a,b,c> <default>`, `debug`, `token`.

- `pr-description.js`: append markdown to a PR description once (pr-description-add, pr-validate `markdown`). Resolves the PR from the `pr` input or the event, so it works outside `pull_request`.
