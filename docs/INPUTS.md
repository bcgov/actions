# Inputs

Actions accept only the inputs they declare in `action.yml`. An unknown or renamed key fails the job loudly instead of GitHub's default warning ("Unexpected input(s)"), which silently ignores it. The check (`shared/inputs.js` `assert-known`) names the bad key, the current name when there is one, and links here.

Old names are never accepted. The tables below are a reference for that error text, listing current names and old -> new; the rename map in `shared/inputs.js` exists only to improve the message and is dropped at v2.

## Renamed and removed in v0.11

Renamed inputs: change the key, keep the value.

| Action | Old input | New input |
|---|---|---|
| builder | `build_file` | `file` |
| builder | `build_context` | `context` |
| builder | `ref` | `base` (diff base; checkouts keep `ref`) |
| diff-triggers | `ref` | `base` |
| image-tracker | `package` | `packages` (one per line, or a single value) |
| image-tracker | `dir` | `working_directory` |
| pr-description-add | `add_markdown` | `markdown` |
| pr-validate | `add_markdown` | `markdown` |
| test-and-analyse | `dir` | `working_directory` |
| test-and-analyse | `ref` | `base` |
| test-and-analyse | `dep_scan` | `unused_deps` (`off`, `warn`, `error`) |
| get-pr | `github_token` | `token` (get-pr is no longer in this repo) |

Removed inputs: delete the key.

| Action | Removed |
|---|---|
| all | `debug` (re-run with debug logging instead; `RUNNER_DEBUG=1`) |
| builder | `sbom`, `repository`, `username` |
| diff-triggers | `annotations` |
| image-tracker | `registry` |
| pr-validate | `conventional_commits` |
| test-and-analyse | `node_version_file`, `java_version_file`, `python_version_file`, `repository`, `branch`, `checkout_path`, `require_sonar` (the action no longer checks out code: run `actions/checkout` yourself and point `working_directory` at it) |
| workflow-notifier | `labels`, `assign` |
| workflow-results | `summary`, `annotations` |

List inputs take one item per line, or a single value (see [shared/README.md](../shared/README.md)).

## bcgov/actions-openshift

[bcgov/actions-openshift](https://github.com/bcgov/actions-openshift) runs a copy of the same check (`shared/assert-known.sh`) and links here; there is no second guide.

### v0.6

| Action | Old input | New input |
|---|---|---|
| crunchy | `diff_branch` | `base` |
| deployer | `ref` | `base` |
| oc-runner | `diff_branch` | `base` |
| oc-runner | `verbose` | `debug` |

Removed: `login_attempts` (deployer, oc-runner).
