# PR Description Add

Appends `markdown` to a pull request description once. A later run with the same
block (checkbox state ignored) does nothing. Works outside `pull_request` events,
e.g. after a deploy: pass `pr`, or it is read from the event (`issue_comment` on a
PR, `workflow_run`).

Fork pull requests get a notice and no change (the token is read-only).

## Permissions

```yaml
permissions:
  pull-requests: write
```

## Usage

```yaml
- uses: bcgov/actions/pr-description-add@vX.Y.Z # Replace with latest release tag
  with:
    markdown: |
      Deployed to [dev](https://example.apps.silver.devops.gov.bc.ca)
```

Outside a `pull_request` event:

```yaml
- uses: bcgov/actions/pr-description-add@vX.Y.Z
  with:
    pr: ${{ steps.track.outputs.pr }} # e.g. image-tracker's pr output
    markdown: Deployed to TEST
```

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `markdown` | yes | | Markdown to append once |
| `pr` | no | event PR | PR number to update |
| `token` | no | `github.token` | Token with `pull-requests: write` |

`pr-validate` has the same `markdown` input as shorthand on `pull_request` events.
