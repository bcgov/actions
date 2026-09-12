import {debug, error, getInput, info, notice, setFailed} from '@actions/core'
import {context, getOctokit} from '@actions/github'
import {normalizeCheckboxState, normalizeText} from './compare.js'

const markdown = getInput('add_markdown', {required: true})
const token = getInput('token', {required: true})
const debugEnabled = getInput('debug') === 'true'

function logDebug(message: string): void {
  debug(message)
  if (debugEnabled) {
    info(message)
  }
}

async function action(): Promise<void> {
  if (!context.payload.pull_request) {
    setFailed('Error: No pull request found in context. Exiting.')
    return
  }

  if (context.payload.pull_request.head.repo.fork) {
    notice(
      'Cannot update PR descriptions from fork workflows (read-only token on the base repo). See https://github.com/bcgov/actions/blob/main/README.md#fork-pull-requests'
    )
    return
  }

  const prNumber = context.payload.pull_request.number
  const octokit = getOctokit(token)
  logDebug(`Fetching current body for PR #${prNumber}`)

  let currentBody: string
  try {
    const {data: pr} = await octokit.rest.pulls.get({
      owner: context.repo.owner,
      repo: context.repo.repo,
      pull_number: prNumber
    })
    currentBody = pr.body || ''
  } catch (err) {
    setFailed(
      `Failed to fetch PR from API: ${err instanceof Error ? err.message : String(err)}. Aborting update to avoid overwriting the current description.`
    )
    return
  }

  const bodyForComparison = normalizeCheckboxState(normalizeText(currentBody))
  const markdownForComparison = normalizeCheckboxState(normalizeText(markdown))
  logDebug(`Normalized add_markdown length: ${markdownForComparison.length}`)

  if (bodyForComparison.includes(markdownForComparison)) {
    info(
      'Markdown message is already present (excluding checkbox state). Exiting.'
    )
    return
  }

  const updatedBody = currentBody
    ? `${currentBody.trim()}\n\n${markdown}`
    : markdown

  info('Description is being updated.')
  try {
    await octokit.rest.pulls.update({
      owner: context.repo.owner,
      repo: context.repo.repo,
      pull_number: prNumber,
      body: updatedBody
    })
    info('Successfully updated PR description.')
  } catch (err) {
    const errorMessage = err instanceof Error ? err.message : String(err)
    const statusCode = (err as {status?: number})?.status

    if (statusCode === 404) {
      error('PR not found. It may have been deleted.')
    } else if (statusCode === 403) {
      error('Permission denied. Check token permissions.')
    } else {
      error(`Failed to update PR: ${errorMessage}`)
    }
    throw err
  }
}

;(async () => {
  try {
    await action()
  } catch (err) {
    setFailed(
      `Unexpected error: ${err instanceof Error ? err.message : String(err)}`
    )
  }
})()
