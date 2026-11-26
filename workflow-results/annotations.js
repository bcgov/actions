const {
  InputError,
  getToken,
  isDebug,
  parseBool
} = require('../shared/inputs.js')
const fs = require('fs')
const process = require('process')

const UNEXPECTED_INPUT = 'Unexpected input(s)'
const PER_PAGE = 100

/**
 * Error raised when the token can't read jobs or annotations (403/404).
 * The check is skipped with a warning instead of failing the gate.
 */
class NotPermittedError extends Error {}

/**
 * GET a GitHub API list endpoint, following pagination.
 * @param {string} url - first page URL, without per_page/page
 * @param {string} key - array key in the response body, or '' for a bare array
 * @param {{ token: string, fetchImpl: typeof fetch, permission: string }} ctx
 * @returns {Promise<object[]>}
 */
async function getAll(url, key, ctx) {
  const items = []
  for (let page = 1; ; page++) {
    const sep = url.includes('?') ? '&' : '?'
    const res = await ctx.fetchImpl(
      `${url}${sep}per_page=${PER_PAGE}&page=${page}`,
      {
        headers: {
          Accept: 'application/vnd.github+json',
          Authorization: `Bearer ${ctx.token}`,
          'X-GitHub-Api-Version': '2022-11-28'
        }
      }
    )
    if (res.status === 403 || res.status === 404) {
      throw new NotPermittedError(
        `${res.status} reading ${url} (token needs ${ctx.permission})`
      )
    }
    if (!res.ok) {
      throw new Error(`${res.status} reading ${url}`)
    }
    const body = await res.json()
    const batch = key ? body[key] : body
    if (!Array.isArray(batch)) {
      throw new Error(`Unexpected response shape from ${url}`)
    }
    items.push(...batch)
    if (batch.length < PER_PAGE) return items
  }
}

/**
 * True for annotations that mean a job that concluded success hid a problem:
 * any error (failure level, e.g. ::error:: or ##[error]) and GitHub's
 * 'Unexpected input(s)' warning for undeclared `with:` inputs.
 * @param {{ annotation_level?: string, message?: string }} annotation
 * @returns {boolean}
 */
function isFinding(annotation) {
  if (annotation.annotation_level === 'failure') return true
  return String(annotation.message ?? '').includes(UNEXPECTED_INPUT)
}

/**
 * List this run's latest jobs and the findings in those that concluded success.
 * Jobs still running (including the one calling this) are not read.
 * @param {{ apiUrl: string, repository: string, runId: string, token: string, fetchImpl?: typeof fetch }} opts
 * @returns {Promise<{ job: string, level: string, message: string, path: string, line: number|null }[]>}
 */
async function collectFindings(opts) {
  const fetchImpl = opts.fetchImpl ?? fetch
  const base = `${opts.apiUrl}/repos/${opts.repository}`
  const jobs = await getAll(
    `${base}/actions/runs/${opts.runId}/jobs?filter=latest`,
    'jobs',
    {token: opts.token, fetchImpl, permission: 'actions: read'}
  )
  const findings = []
  for (const job of jobs) {
    if (job.status !== 'completed' || job.conclusion !== 'success') continue
    const annotations = await getAll(
      `${base}/check-runs/${job.id}/annotations`,
      '',
      {token: opts.token, fetchImpl, permission: 'checks: read'}
    )
    for (const a of annotations) {
      if (!isFinding(a)) continue
      findings.push({
        job: job.name,
        level: a.annotation_level,
        message: String(a.message ?? '').trim(),
        path: a.path ?? '',
        line: a.start_line ?? null
      })
    }
  }
  return findings
}

/**
 * Escape a value for a workflow command message.
 * @param {string} s
 * @returns {string}
 */
function escapeData(s) {
  return String(s)
    .replace(/%/g, '%25')
    .replace(/\r/g, '%0D')
    .replace(/\n/g, '%0A')
}

/**
 * Escape a value for a workflow command property such as title.
 * @param {string} s
 * @returns {string}
 */
function escapeProperty(s) {
  return escapeData(s).replace(/:/g, '%3A').replace(/,/g, '%2C')
}

/**
 * Markdown section for GITHUB_STEP_SUMMARY.
 * @param {string} title
 * @param {ReturnType<typeof collectFindings> extends Promise<infer T> ? T : never} findings
 * @returns {string}
 */
function buildSummary(title, findings) {
  const lines = [`### ${title}: annotations\n`]
  if (findings.length === 0) {
    lines.push(
      '> ✅ **No errors or unexpected inputs in jobs that concluded success.**'
    )
  } else {
    lines.push('| Job | Level | Annotation |')
    lines.push('| :--- | :--- | :--- |')
    const cell = s =>
      String(s)
        .replace(/\\/g, '\\\\')
        .replace(/\|/g, '\\|')
        .replace(/\r?\n/g, ' ')
    for (const f of findings) {
      lines.push(`| \`${cell(f.job)}\` | ${f.level} | ${cell(f.message)} |`)
    }
    lines.push('')
    lines.push(
      `> ❌ **${findings.length} error or unexpected-input annotation(s) in jobs that concluded success.** Fix them, or set \`check_annotations: false\` if they are intended.`
    )
  }
  lines.push('')
  return lines.join('\n')
}

/**
 * Run the annotation check.
 * @param {object} [opts]
 * @returns {Promise<{ exitCode: number, findings: object[]|null }>}
 */
async function run(opts = {}) {
  const env = opts.env ?? process.env
  const logger = opts.logger ?? console
  const title = String(env.INPUT_TITLE ?? '').trim() || 'Workflow Results'
  const outputPath = env.GITHUB_OUTPUT
  const summaryPath = env.GITHUB_STEP_SUMMARY
  const writeOutput = value => {
    if (outputPath) fs.appendFileSync(outputPath, `annotations=${value}\n`)
  }

  if (!parseBool(env.INPUT_CHECK_ANNOTATIONS, 'check_annotations', true)) {
    logger.log('Annotation check off (check_annotations: false)')
    writeOutput('')
    return {exitCode: 0, findings: null}
  }

  let findings
  try {
    findings = await collectFindings({
      apiUrl: env.GITHUB_API_URL || 'https://api.github.com',
      repository: env.GITHUB_REPOSITORY,
      runId: env.GITHUB_RUN_ID,
      token: getToken(env),
      fetchImpl: opts.fetchImpl
    })
  } catch (err) {
    const why =
      err instanceof NotPermittedError
        ? `${err.message}. Grant the results job actions: read and checks: read`
        : err.message
    logger.warn(
      `::warning title=${escapeProperty(`${title}: annotations not checked`)}::Skipped the annotation check: ${escapeData(why)}`
    )
    writeOutput('')
    return {exitCode: 0, findings: null}
  }

  if (isDebug(env)) {
    logger.log(`::debug::Annotation findings: ${JSON.stringify(findings)}`)
  }
  for (const f of findings) {
    const where = f.path ? ` (${f.path}${f.line ? `:${f.line}` : ''})` : ''
    logger.error(
      `::error title=${escapeProperty(`${title}: ${f.job}`)}::Job '${escapeData(f.job)}' concluded success but has a ${f.level} annotation${escapeData(where)}: ${escapeData(f.message)}`
    )
  }
  if (summaryPath) {
    try {
      fs.appendFileSync(summaryPath, buildSummary(title, findings), 'utf8')
    } catch (err) {
      logger.warn(`::warning::Failed to write step summary: ${err.message}`)
    }
  }
  writeOutput(JSON.stringify(findings))
  return {exitCode: findings.length === 0 ? 0 : 1, findings}
}

if (require.main === module) {
  run()
    .then(({exitCode}) => process.exit(exitCode))
    .catch(err => {
      const msg =
        err instanceof InputError
          ? err.message
          : `::error::${err.message || err}`
      console.error(msg)
      process.exit(1)
    })
}

module.exports = {
  NotPermittedError,
  buildSummary,
  collectFindings,
  escapeProperty,
  isFinding,
  run
}
