# Input Enforcer

Fail when a caller passes an input the action does not declare. GitHub on its own only warns ("Unexpected input(s)") on an undeclared `with:` key and keeps going, so a typo or stale key is silently ignored.

The check is declare-vs-given only: it reads the calling action's `action.yml` and the keys passed. Nothing is configured per action. The error names each bad key, lists the declared inputs and links the action's README:

```
Unknown input(s) for builder: build_file
  build_file: not an input of builder
Inputs: package, context, file, ...
Docs: https://github.com/bcgov/actions/blob/main/builder/README.md
```

## Usage

Composite actions run it as their first step:

```yaml
runs:
  using: composite
  steps:
    - name: Check inputs
      uses: bcgov/actions/input-enforcer@<sha> # inside bcgov/actions: $/input-enforcer
      with:
        inputs: ${{ toJSON(inputs) }}
        action_path: ${{ github.action_path }}
```

`toJSON(inputs)` holds undeclared keys too. Keys compare case-insensitively as written; a spaced key such as `build args` does not match `build_args`.

Node actions in this repo call the same module first, against the runner's `INPUT_*` env (spaces as `_`, as the runner sets them):

```js
require('../input-enforcer/enforce.js').enforceNode(__dirname);
```

## Inputs

| Input | Description |
|---|---|
| `inputs` | Always `${{ toJSON(inputs) }}` |
| `action_path` | Always `${{ github.action_path }}` |

CLI (tests, CI): `node input-enforcer/enforce.js <action_dir> '<inputs json>'`.
