const fs = require('fs')
const process = require('process')

/**
 * Parse the needs context input.
 * @param {string|object} raw
 * @returns {Record<string, { result?: string, outputs?: Record<string, unknown> }>}
 */
function parseNeeds(raw) {
  if (!raw) {
    throw new Error("Input 'needs' is required and must not be empty.")
  }

  let parsed
  if (typeof raw === 'object' && raw !== null) {
    parsed = raw
  } else if (typeof raw === 'string') {
    const trimmed = raw.trim()
    if (!trimmed) {
      throw new Error("Input 'needs' is required and must not be empty.")
    }
    try {
      parsed = JSON.parse(trimmed)
    } catch (err) {
      throw new Error(`Failed to parse 'needs' input as JSON: ${err.message}`, {
        cause: err
      })
    }
  } else {
    throw new Error("Input 'needs' must be a valid JSON string or object.")
  }

  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw new Error(
      "Input 'needs' must be an object mapping job keys to results."
    )
  }

  const keys = Object.keys(parsed)
  if (keys.length === 0) {
    throw new Error(
      "No upstream jobs found in needs context. Verify that 'needs: [...]' is specified on the calling job."
    )
  }

  return parsed
}

/**
 * Normalize and categorize upstream job results.
 * @param {Record<string, unknown>} needs
 * @returns {{
 *   passed: boolean,
 *   successes: string[],
 *   skipped: string[],
 *   failed: string[],
 *   cancelled: string[],
 *   unknown: { key: string, status: string }[],
 *   total: number,
 *   details: { key: string, status: string, normalized: string }[]
 * }}
 */
function evaluateResults(needs) {
  const successes = []
  const skipped = []
  const failed = []
  const cancelled = []
  const unknown = []
  const details = []

  for (const [key, val] of Object.entries(needs)) {
    let rawStatus = ''
    if (typeof val === 'string') {
      rawStatus = val
    } else if (val && typeof val === 'object' && 'result' in val) {
      rawStatus = String(val.result || '')
    }

    const normalized = rawStatus.trim().toLowerCase()

    if (normalized === 'success') {
      successes.push(key)
      details.push({key, status: rawStatus || 'success', normalized: 'success'})
    } else if (normalized === 'skipped') {
      skipped.push(key)
      details.push({key, status: rawStatus || 'skipped', normalized: 'skipped'})
    } else if (normalized === 'cancelled' || normalized === 'canceled') {
      cancelled.push(key)
      details.push({
        key,
        status: rawStatus || 'cancelled',
        normalized: 'cancelled'
      })
    } else if (normalized === 'failure') {
      failed.push(key)
      details.push({key, status: rawStatus || 'failure', normalized: 'failure'})
    } else {
      unknown.push({key, status: rawStatus})
      details.push({key, status: rawStatus || 'unknown', normalized: 'unknown'})
    }
  }

  const passed =
    failed.length === 0 && cancelled.length === 0 && unknown.length === 0

  return {
    passed,
    successes,
    skipped,
    failed,
    cancelled,
    unknown,
    total: details.length,
    details
  }
}

/**
 * Build Markdown table for GITHUB_STEP_SUMMARY.
 * @param {string} title
 * @param {ReturnType<typeof evaluateResults>} evaluation
 * @returns {string}
 */
function buildSummary(title, evaluation) {
  const lines = [`### ${title}\n`]
  lines.push('| Job | Result |')
  lines.push('| :--- | :--- |')

  for (const item of evaluation.details) {
    let badge
    switch (item.normalized) {
      case 'success':
        badge = '✅ Succeeded'
        break
      case 'skipped':
        badge = '⊘ Skipped'
        break
      case 'cancelled':
        badge = '🛑 Cancelled'
        break
      case 'failure':
        badge = '❌ Failed'
        break
      default:
        badge = `⚠️ Unknown (${item.status || 'missing'})`
        break
    }
    lines.push(`| \`${item.key}\` | ${badge} |`)
  }

  lines.push('')
  if (evaluation.passed) {
    lines.push(
      `> ✅ **All upstream checks passed or were intentionally skipped** (${evaluation.successes.length} passed, ${evaluation.skipped.length} skipped).`
    )
  } else {
    const reasons = []
    if (evaluation.failed.length > 0) {
      reasons.push(
        `${evaluation.failed.length} failed (\`${evaluation.failed.join('`, `')}\`)`
      )
    }
    if (evaluation.cancelled.length > 0) {
      reasons.push(
        `${evaluation.cancelled.length} cancelled (\`${evaluation.cancelled.join('`, `')}\`)`
      )
    }
    if (evaluation.unknown.length > 0) {
      const unknownKeys = evaluation.unknown.map(u => u.key)
      reasons.push(
        `${evaluation.unknown.length} unknown status (\`${unknownKeys.join('`, `')}\`)`
      )
    }
    lines.push(
      `> ❌ **Check Failure: At least one upstream check did not succeed** (${reasons.join(', ')}).`
    )
  }
  lines.push('')

  return lines.join('\n')
}

/**
 * Main action runner.
 * @param {object} [opts]
 * @returns {{ exitCode: number, evaluation: ReturnType<typeof evaluateResults>, markdown: string }}
 */
function run(opts = {}) {
  const rawNeeds = opts.needsInput ?? process.env.INPUT_NEEDS
  const title =
    (opts.title ?? process.env.INPUT_TITLE ?? 'PR Results').trim() ||
    'PR Results'
  const enableSummary =
    (opts.summary ?? process.env.INPUT_SUMMARY ?? 'true') !== 'false'
  const enableAnnotations =
    (opts.annotations ?? process.env.INPUT_ANNOTATIONS ?? 'true') !== 'false'
  const outputPath = opts.outputPath ?? process.env.GITHUB_OUTPUT
  const summaryPath = opts.summaryPath ?? process.env.GITHUB_STEP_SUMMARY
  const logger = opts.logger ?? console

  const needs = parseNeeds(rawNeeds)
  const evaluation = evaluateResults(needs)
  const markdown = buildSummary(title, evaluation)

  // 1. Log overview
  if (logger.group && process.env.GITHUB_ACTIONS === 'true') {
    logger.group(`=== ${title} ===`)
    for (const item of evaluation.details) {
      logger.log(`  [${item.normalized}] ${item.key}`)
    }
    logger.groupEnd()
  } else {
    logger.log(`\n=== ${title} ===`)
    for (const item of evaluation.details) {
      logger.log(`  [${item.normalized}] ${item.key}`)
    }
  }

  // 2. Emit Annotations
  if (enableAnnotations) {
    for (const key of evaluation.failed) {
      logger.error(`::error::Job '${key}' failed.`)
    }
    for (const key of evaluation.cancelled) {
      logger.error(`::error::Job '${key}' was cancelled.`)
    }
    for (const item of evaluation.unknown) {
      logger.error(
        `::error::Job '${item.key}' had unexpected or missing status: '${item.status}'.`
      )
    }
  }

  // 3. Write Step Summary
  if (enableSummary && summaryPath) {
    try {
      fs.appendFileSync(summaryPath, markdown, 'utf8')
    } catch (err) {
      logger.warn(`::warning::Failed to write step summary: ${err.message}`)
    }
  }

  // 4. Write Output Variables
  if (outputPath) {
    try {
      const outputLines = [
        `passed=${evaluation.passed}`,
        `failed=${JSON.stringify(evaluation.failed)}`,
        `cancelled=${JSON.stringify(evaluation.cancelled)}`,
        `skipped=${JSON.stringify(evaluation.skipped)}`,
        `total=${evaluation.total}`
      ]
      fs.appendFileSync(outputPath, outputLines.join('\n') + '\n', 'utf8')
    } catch (err) {
      logger.warn(`::warning::Failed to write outputs: ${err.message}`)
    }
  }

  const exitCode = evaluation.passed ? 0 : 1
  return {exitCode, evaluation, markdown}
}

if (require.main === module) {
  try {
    const {exitCode} = run()
    process.exit(exitCode)
  } catch (err) {
    console.error(`::error::${err.message || err}`)
    process.exit(1)
  }
}

module.exports = {
  parseNeeds,
  evaluateResults,
  buildSummary,
  run
}
