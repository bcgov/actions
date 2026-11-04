# Migration guide

Actions fail when a caller passes an input they do not declare. GitHub on its own only warns ("Unexpected input(s)") and carries on, so a renamed input was silently ignored and the job failed later, somewhere else. The check (`shared/inputs.js` `assert-known`) names the bad key, its replacement when there is one, and links here.

Old names are never accepted. The rename map in `shared/inputs.js` only improves the error text; estimated removal is v2.

## v0.11

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
| test-and-analyse | `node_version_file`, `java_version_file`, `python_version_file`, `repository`, `branch`, `checkout_path`, `require_sonar` |
| workflow-notifier | `labels`, `assign` |
| workflow-results | `summary`, `annotations` |

List inputs take one item per line, or a single value (see [shared/README.md](../shared/README.md)).

## Downstream

[bcgov/actions-openshift](https://github.com/bcgov/actions-openshift) runs a copy of the same check and links to this guide.
