const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const os = require('node:os')
const {
  NotPermittedError,
  buildSummary,
  collectFindings,
  escapeProperty,
  isFinding,
  run
} = require('../annotations.js')

const API = 'https://api.github.com'
const REPO = 'bcgov/demo'
const RUN = '42'

/** Fake fetch serving pages from a URL -> body map; records calls. */
function fakeFetch(routes, calls = []) {
  return async url => {
    calls.push(url)
    const hit = routes[url]
    if (hit === undefined)
      return {ok: false, status: 500, json: async () => ({})}
    if (typeof hit === 'number')
      return {ok: false, status: hit, json: async () => ({})}
    return {ok: true, status: 200, json: async () => hit}
  }
}

const jobsUrl = page =>
  `${API}/repos/${REPO}/actions/runs/${RUN}/jobs?filter=latest&per_page=100&page=${page}`
const annUrl = (id, page) =>
  `${API}/repos/${REPO}/check-runs/${id}/annotations?per_page=100&page=${page}`

const unexpected = {
  annotation_level: 'warning',
  message: "Unexpected input(s) 'not_an_input', valid inputs are ['message']",
  path: '.github',
  start_line: 1
}
const error = {
  annotation_level: 'failure',
  message: 'fixture error',
  path: '.github'
}
const notice = {annotation_level: 'notice', message: 'just a notice'}
const deprecation = {
  annotation_level: 'warning',
  message: 'Node.js 20 is deprecated'
}

function tmpEnv(extra = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wr-annotations-'))
  const out = path.join(dir, 'out')
  const summary = path.join(dir, 'summary')
  fs.writeFileSync(out, '')
  fs.writeFileSync(summary, '')
  return {
    out,
    summary,
    env: {
      GITHUB_API_URL: API,
      GITHUB_REPOSITORY: REPO,
      GITHUB_RUN_ID: RUN,
      GITHUB_OUTPUT: out,
      GITHUB_STEP_SUMMARY: summary,
      INPUT_TOKEN: 'tkn',
      INPUT_TITLE: 'PR Results',
      ...extra
    }
  }
}

function quietLogger() {
  const lines = {log: [], warn: [], error: []}
  return {
    lines,
    log: m => lines.log.push(m),
    warn: m => lines.warn.push(m),
    error: m => lines.error.push(m)
  }
}

test('isFinding: errors and Unexpected input(s) only', () => {
  assert.equal(isFinding(error), true)
  assert.equal(isFinding(unexpected), true)
  assert.equal(isFinding(notice), false)
  assert.equal(isFinding(deprecation), false)
  assert.equal(isFinding({}), false)
})

test('collectFindings: reads only completed jobs that concluded success', async () => {
  const calls = []
  const findings = await collectFindings({
    apiUrl: API,
    repository: REPO,
    runId: RUN,
    token: 't',
    fetchImpl: fakeFetch(
      {
        [jobsUrl(1)]: {
          jobs: [
            {id: 1, name: 'Builds', status: 'completed', conclusion: 'success'},
            {id: 2, name: 'Tests', status: 'completed', conclusion: 'failure'},
            {
              id: 3,
              name: 'PR Results',
              status: 'in_progress',
              conclusion: null
            },
            {id: 4, name: 'Skipped', status: 'completed', conclusion: 'skipped'}
          ]
        },
        [annUrl(1, 1)]: [unexpected, error, notice, deprecation]
      },
      calls
    )
  })
  assert.deepEqual(
    findings.map(f => [f.job, f.level]),
    [
      ['Builds', 'warning'],
      ['Builds', 'failure']
    ]
  )
  assert.equal(findings[0].line, 1)
  assert.equal(findings[1].line, null)
  assert.ok(!calls.some(u => /check-runs\/[234]\//.test(u)), 'only job 1 read')
})

test('collectFindings: follows pagination for jobs and annotations', async () => {
  const jobsPage1 = Array.from({length: 100}, (_, i) => ({
    id: 1000 + i,
    name: `job-${i}`,
    status: 'completed',
    conclusion: 'skipped'
  }))
  const routes = {
    [jobsUrl(1)]: {jobs: jobsPage1},
    [jobsUrl(2)]: {
      jobs: [{id: 7, name: 'Late', status: 'completed', conclusion: 'success'}]
    },
    [annUrl(7, 1)]: Array.from({length: 100}, () => notice),
    [annUrl(7, 2)]: [error]
  }
  const findings = await collectFindings({
    apiUrl: API,
    repository: REPO,
    runId: RUN,
    token: 't',
    fetchImpl: fakeFetch(routes)
  })
  assert.deepEqual(
    findings.map(f => f.job),
    ['Late']
  )
})

test('collectFindings: 403 raises NotPermittedError naming the permission', async () => {
  await assert.rejects(
    collectFindings({
      apiUrl: API,
      repository: REPO,
      runId: RUN,
      token: 't',
      fetchImpl: fakeFetch({[jobsUrl(1)]: 403})
    }),
    err => err instanceof NotPermittedError && /actions: read/.test(err.message)
  )
  await assert.rejects(
    collectFindings({
      apiUrl: API,
      repository: REPO,
      runId: RUN,
      token: 't',
      fetchImpl: fakeFetch({
        [jobsUrl(1)]: {
          jobs: [{id: 1, name: 'A', status: 'completed', conclusion: 'success'}]
        },
        [annUrl(1, 1)]: 403
      })
    }),
    err => err instanceof NotPermittedError && /checks: read/.test(err.message)
  )
})

test('run: findings fail with annotations, summary and JSON output', async () => {
  const t = tmpEnv()
  const logger = quietLogger()
  const r = await run({
    env: t.env,
    logger,
    fetchImpl: fakeFetch({
      [jobsUrl(1)]: {
        jobs: [
          {id: 1, name: 'Fixture', status: 'completed', conclusion: 'success'}
        ]
      },
      [annUrl(1, 1)]: [unexpected, error]
    })
  })
  assert.equal(r.exitCode, 1)
  assert.equal(logger.lines.error.length, 2)
  assert.match(
    logger.lines.error[0],
    /^::error title=PR Results%3A Fixture::Job 'Fixture' concluded success/
  )
  assert.match(logger.lines.error[0], /Unexpected input\(s\)/)
  const out = fs.readFileSync(t.out, 'utf8')
  const json = JSON.parse(out.replace(/^annotations=/, ''))
  assert.equal(json.length, 2)
  assert.match(
    fs.readFileSync(t.summary, 'utf8'),
    /2 error or unexpected-input annotation/
  )
})

test('run: clean run passes with [] output', async () => {
  const t = tmpEnv()
  const r = await run({
    env: t.env,
    logger: quietLogger(),
    fetchImpl: fakeFetch({
      [jobsUrl(1)]: {
        jobs: [
          {id: 1, name: 'Clean', status: 'completed', conclusion: 'success'}
        ]
      },
      [annUrl(1, 1)]: [notice, deprecation]
    })
  })
  assert.equal(r.exitCode, 0)
  assert.equal(fs.readFileSync(t.out, 'utf8'), 'annotations=[]\n')
  assert.match(
    fs.readFileSync(t.summary, 'utf8'),
    /No errors or unexpected inputs/
  )
})

test('run: no permission warns and skips with empty output', async () => {
  const t = tmpEnv()
  const logger = quietLogger()
  const r = await run({
    env: t.env,
    logger,
    fetchImpl: fakeFetch({[jobsUrl(1)]: 403})
  })
  assert.equal(r.exitCode, 0)
  assert.equal(r.findings, null)
  assert.match(
    logger.lines.warn[0],
    /^::warning title=PR Results%3A annotations not checked::/
  )
  assert.match(logger.lines.warn[0], /actions: read and checks: read/)
  assert.equal(fs.readFileSync(t.out, 'utf8'), 'annotations=\n')
})

test('run: other API errors warn and skip', async () => {
  const t = tmpEnv()
  const logger = quietLogger()
  const r = await run({env: t.env, logger, fetchImpl: fakeFetch({})})
  assert.equal(r.exitCode, 0)
  assert.match(logger.lines.warn[0], /500 reading/)
})

test('run: check_annotations false makes no API calls', async () => {
  const t = tmpEnv({INPUT_CHECK_ANNOTATIONS: 'false'})
  const calls = []
  const r = await run({
    env: t.env,
    logger: quietLogger(),
    fetchImpl: fakeFetch({}, calls)
  })
  assert.equal(r.exitCode, 0)
  assert.equal(calls.length, 0)
  assert.equal(fs.readFileSync(t.out, 'utf8'), 'annotations=\n')
})

test('run: invalid check_annotations throws', async () => {
  const t = tmpEnv({INPUT_CHECK_ANNOTATIONS: 'yes'})
  await assert.rejects(
    run({env: t.env, logger: quietLogger(), fetchImpl: fakeFetch({})}),
    /check_annotations/
  )
})

test('buildSummary: escapes pipes and newlines', () => {
  const md = buildSummary('T', [
    {job: 'a|b', level: 'failure', message: 'x\ny|z', path: '', line: null}
  ])
  assert.match(md, /`a\\\|b`/)
  assert.match(md, /x y\\\|z/)
})

test('escapeProperty: escapes command property separators', () => {
  assert.equal(escapeProperty('Test (a, b): x%\n'), 'Test (a%2C b)%3A x%25%0A')
})
