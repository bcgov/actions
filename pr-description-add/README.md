
# Add to Pull Request Descriptions

This action adds to Pull Request descriptions using markdown.  It checks if the message is already present before adding.

Prefer a sticky PR comment for deployment links and other bot-owned text.
Mutating the description races with authors, pollutes squash commit
messages, and posts links before deploy finishes. New consumers should
not start here; existing ones can migrate with
[`marocchino/sticky-pull-request-comment`](https://github.com/marocchino/sticky-pull-request-comment)
after a successful deploy:

```yaml
# After deploy succeeds in pr-open.yml
- name: Post deploy links
  uses: marocchino/sticky-pull-request-comment@v2
  with:
    header: pr-deployment-links
    message: |
      ### Deployments
      - [Frontend](https://${{ github.event.repository.name }}-${{ github.event.number }}.apps.silver.devops.gov.bc.ca)

# On PR close
- name: Remove deploy links
  uses: marocchino/sticky-pull-request-comment@v2
  with:
    header: pr-deployment-links
    delete: true
```

`pr-validate` should stay on `bcgov/actions/pr-validate@<release>` and
should not take `markdown_links`. See #196.

## Input

#### Required

`add_markdown`: The message to add to pull requests, in markdown.

#### Optional

`token`: ${{ secrets.GITHUB_TOKEN }} or a Personal Access Token (PAT).  Default is to inherit a token from the calling workflow.

`debug`: Set to `"true"` to print extra `info` logs (GitHub `debug` logs are always emitted).

## Permissions

To run this action, the calling workflow job must have the following minimum permissions:

```yaml
permissions:
  pull-requests: write
```



## Fork pull requests

Fork PRs cannot update the upstream PR description — GitHub grants a read-only token on the base repo. The action detects fork PRs, emits a notice, and exits successfully. See the [fork pull requests guide](https://github.com/bcgov/actions/blob/main/README.md#fork-pull-requests).

## Example #1, minimal

Create or modify a GitHub workflow, like below.  E.g. `.github/workflows/pr-append.yml`

```yaml
name: "Add to Pull Request Description"
on:
  pull_request:

jobs:
  test:
    runs-on: ubuntu-24.04
    steps:
      - uses: bcgov/actions/pr-description-add@vX.Y.Z
        with:
          add_markdown: |
            ---

            # Things!
            ## Excitement!
            [Links!](https://google.ca)
            `Code!`
```

## Example #2, advanced


```yaml
name: "Add to Pull Request Description"
on:
  pull_request:

jobs:
  test:
    name: PR Greeting
    permissions:
      pull-requests: write
    runs-on: ubuntu-24.04
    steps:
      - uses: bcgov/actions/pr-description-add@vX.Y.Z
        with:
          token: "${{ secrets.GITHUB_TOKEN }}"
          add_markdown: |
            ---

            # Things!
            ## Excitement!
            [Links!](https://google.ca)
            `Code!`
            _Italics_
            *Bold*
            * Bullets!
            * and [more reading!](https://github.github.com/gfm/)
```

## Issues and Discussions

Please submit issues (bugs, feature requests) and take part in discussions at the links below.

BC Government QuickStart for OpenShift - [Issues](https://github.com/bcgov/quickstart-openshift/issues)

BC Government QuickStart for OpenShift - [Discussions](https://github.com/bcgov/quickstart-openshift/discussions)


## Contributing

Contributions are always welcome!  Please send us pull requests or get in touch at the links above.

## Acknowledgements

This Action is provided courtesy of NRIDS Architecture and Forestry Digital Services, parts of the Government of British Columbia.
