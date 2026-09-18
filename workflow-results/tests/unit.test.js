const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const os = require('node:os')
const {parseNeeds, evaluateResults, buildSummary, run} = require('../index.js')

test('parseNeeds: throws on empty or invalid inputs', () => {
  assert.throws(() => parseNeeds(''), /Input 'needs' is required/)
  assert.throws(() => parseNeeds('   '), /Input 'needs' is required/)
  assert.throws(() => parseNeeds(null), /Input 'needs' is required/)
  assert.throws(
    () => parseNeeds('{ bad json }'),
    /Failed to parse 'needs' input as JSON/
  )
  assert.throws(() => parseNeeds('[]'), /must be an object mapping job keys/)
  assert.throws(() => parseNeeds('123'), /must be an object mapping job keys/)
  assert.throws(
    () => parseNeeds('{}'),
    /No upstream jobs found in needs context/
  )
  assert.throws(() => parseNeeds({}), /No upstream jobs found in needs context/)
})

test('parseNeeds: accepts valid JSON string or object', () => {
  const jsonStr = '{"jobA": {"result": "success"}}'
  const parsed = parseNeeds(jsonStr)
  assert.deepEqual(parsed, {jobA: {result: 'success'}})

  const obj = {jobB: {result: 'skipped'}}
  assert.deepEqual(parseNeeds(obj), obj)
})

test('evaluateResults: passes with all success', () => {
  const needs = {
    build: {result: 'success'},
    test: {result: 'success'}
  }
  const evalResult = evaluateResults(needs)
  assert.equal(evalResult.passed, true)
  assert.deepEqual(evalResult.successes, ['build', 'test'])
  assert.deepEqual(evalResult.skipped, [])
  assert.deepEqual(evalResult.failed, [])
  assert.deepEqual(evalResult.cancelled, [])
  assert.equal(evalResult.total, 2)
})

test('evaluateResults: passes with mixture of success and skipped', () => {
  const needs = {
    filter: {result: 'success'},
    backend: {result: 'skipped'},
    frontend: {result: 'success'}
  }
  const evalResult = evaluateResults(needs)
  assert.equal(evalResult.passed, true)
  assert.deepEqual(evalResult.successes, ['filter', 'frontend'])
  assert.deepEqual(evalResult.skipped, ['backend'])
  assert.deepEqual(evalResult.failed, [])
  assert.deepEqual(evalResult.cancelled, [])
  assert.equal(evalResult.total, 3)
})

test('evaluateResults: fails on failure', () => {
  const needs = {
    unit: {result: 'success'},
    e2e: {result: 'failure'}
  }
  const evalResult = evaluateResults(needs)
  assert.equal(evalResult.passed, false)
  assert.deepEqual(evalResult.failed, ['e2e'])
  assert.deepEqual(evalResult.successes, ['unit'])
})

test('evaluateResults: catches cancelled', () => {
  const needs = {
    lint: {result: 'cancelled'}
  }
  const evalResult = evaluateResults(needs)
  assert.equal(evalResult.passed, false)
  assert.deepEqual(evalResult.cancelled, ['lint'])
})

test('evaluateResults: handles case insensitivity and whitespace', () => {
  const needs = {
    a: {result: ' SUCCESS '},
    b: {result: 'SKIPPED'},
    c: {result: 'Failure'},
    d: {result: ' Cancelled '}
  }
  const evalResult = evaluateResults(needs)
  assert.equal(evalResult.passed, false)
  assert.deepEqual(evalResult.successes, ['a'])
  assert.deepEqual(evalResult.skipped, ['b'])
  assert.deepEqual(evalResult.failed, ['c'])
  assert.deepEqual(evalResult.cancelled, ['d'])
})

test('evaluateResults: flags unknown or missing status as failure', () => {
  const needs = {
    weird: {result: 'in_progress'},
    empty: {}
  }
  const evalResult = evaluateResults(needs)
  assert.equal(evalResult.passed, false)
  assert.equal(evalResult.unknown.length, 2)
  assert.equal(evalResult.unknown[0].key, 'weird')
  assert.equal(evalResult.unknown[1].key, 'empty')
})

test('buildSummary: formats markdown table with icons and summary', () => {
  const evaluation = {
    passed: false,
    successes: ['a'],
    skipped: ['b'],
    failed: ['c'],
    cancelled: ['d'],
    unknown: [],
    total: 4,
    details: [
      {key: 'a', status: 'success', normalized: 'success'},
      {key: 'b', status: 'skipped', normalized: 'skipped'},
      {key: 'c', status: 'failure', normalized: 'failure'},
      {key: 'd', status: 'cancelled', normalized: 'cancelled'}
    ]
  }

  const md = buildSummary('Analysis Results', evaluation)
  assert.ok(md.includes('### Analysis Results'))
  assert.ok(md.includes('| `a` | ✅ Succeeded |'))
  assert.ok(md.includes('| `b` | ⊘ Skipped |'))
  assert.ok(md.includes('| `c` | ❌ Failed |'))
  assert.ok(md.includes('| `d` | 🛑 Cancelled |'))
  assert.ok(
    md.includes(
      '> ❌ **Check Failure: At least one upstream check did not succeed**'
    )
  )
  assert.ok(md.includes('1 failed (`c`)'))
  assert.ok(md.includes('1 cancelled (`d`)'))
})

test('run: end-to-end success writes outputs and step summary with exitCode 0', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'pr-results-test-'))
  const outputPath = path.join(tmpDir, 'output.txt')
  const summaryPath = path.join(tmpDir, 'summary.md')

  const logs = []
  const errors = []
  const mockLogger = {
    log: msg => logs.push(msg),
    error: msg => errors.push(msg),
    warn: msg => logs.push(msg)
  }

  const {exitCode, evaluation} = run({
    needsInput: JSON.stringify({
      build: {result: 'success'},
      lint: {result: 'skipped'}
    }),
    title: 'PR Results',
    outputPath,
    summaryPath,
    logger: mockLogger
  })

  assert.equal(exitCode, 0)
  assert.equal(evaluation.passed, true)
  assert.equal(errors.length, 0)

  const outputContent = fs.readFileSync(outputPath, 'utf8')
  assert.ok(outputContent.includes('passed=true'))
  assert.ok(outputContent.includes('total=2'))
  assert.ok(outputContent.includes('failed=[]'))
  assert.ok(outputContent.includes('skipped=["lint"]'))

  const summaryContent = fs.readFileSync(summaryPath, 'utf8')
  assert.ok(summaryContent.includes('### PR Results'))
  assert.ok(
    summaryContent.includes(
      'All upstream checks passed or were intentionally skipped'
    )
  )

  fs.rmSync(tmpDir, {recursive: true, force: true})
})

test('run: defaults title to Workflow Results when omitted', () => {
  const tmpDir = fs.mkdtempSync(
    path.join(os.tmpdir(), 'workflow-results-test-')
  )
  const outputPath = path.join(tmpDir, 'output.txt')
  const summaryPath = path.join(tmpDir, 'summary.md')

  const {exitCode} = run({
    needsInput: JSON.stringify({
      build: {result: 'success'}
    }),
    outputPath,
    summaryPath,
    logger: {log: () => {}, error: () => {}, warn: () => {}}
  })

  assert.equal(exitCode, 0)
  const summaryContent = fs.readFileSync(summaryPath, 'utf8')
  assert.ok(summaryContent.includes('### Workflow Results'))

  fs.rmSync(tmpDir, {recursive: true, force: true})
})

test('run: end-to-end failure emits annotations and exitCode 1', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'pr-results-test-fail-'))
  const outputPath = path.join(tmpDir, 'output.txt')
  const summaryPath = path.join(tmpDir, 'summary.md')

  const errors = []
  const mockLogger = {
    log: () => {},
    error: msg => errors.push(msg),
    warn: () => {}
  }

  const {exitCode, evaluation} = run({
    needsInput: JSON.stringify({
      build: {result: 'success'},
      test: {result: 'failure'},
      deploy: {result: 'cancelled'}
    }),
    title: 'Deploy Gate',
    outputPath,
    summaryPath,
    logger: mockLogger
  })

  assert.equal(exitCode, 1)
  assert.equal(evaluation.passed, false)
  assert.ok(errors.some(e => e.includes("::error::Job 'test' failed.")))
  assert.ok(
    errors.some(e => e.includes("::error::Job 'deploy' was cancelled."))
  )

  const outputContent = fs.readFileSync(outputPath, 'utf8')
  assert.ok(outputContent.includes('passed=false'))
  assert.ok(outputContent.includes('failed=["test"]'))
  assert.ok(outputContent.includes('cancelled=["deploy"]'))

  fs.rmSync(tmpDir, {recursive: true, force: true})
})

test('buildSummary: escapes backslashes and pipes in job names to preserve markdown table integrity', () => {
  const evaluation = {
    passed: true,
    successes: ['test \\ path | unit'],
    skipped: [],
    failed: [],
    cancelled: [],
    unknown: [],
    total: 1,
    details: [
      {
        key: 'test \\ path | unit',
        status: 'success',
        normalized: 'success'
      }
    ]
  }

  const md = buildSummary('Pipeline Gate', evaluation)
  assert.ok(md.includes('| `test \\\\ path \\| unit` | ✅ Succeeded |'))
})

test('evaluateResults: rejects non-canonical single-l canceled as failure/unknown', () => {
  const needs = {
    test: {result: 'canceled'}
  }
  const evalResult = evaluateResults(needs)
  assert.equal(evalResult.passed, false)
  assert.equal(evalResult.unknown.length, 1)
  assert.equal(evalResult.unknown[0].key, 'test')
  assert.equal(evalResult.unknown[0].status, 'canceled')
})

test('evaluateResults: handles non-standard, null, or malformed job entries safely', () => {
  const needs = {
    nullJob: null,
    numberJob: 42,
    booleanJob: false,
    undefinedJob: undefined
  }
  const evalResult = evaluateResults(needs)
  assert.equal(evalResult.passed, false)
  assert.equal(evalResult.total, 4)
  assert.equal(evalResult.unknown.length, 4)
})

test('evaluateResults: accurately handles real GitHub Actions matrix job graphs', () => {
  const matrixNeeds = {
    filter: {result: 'success', outputs: {changes: '["frontend"]'}},
    'test (18, ubuntu-24.04)': {result: 'success', outputs: {}},
    'test (20, ubuntu-24.04)': {result: 'success', outputs: {}},
    'test (22, ubuntu-24.04)': {result: 'skipped', outputs: {}},
    'deploy (dev)': {
      result: 'success',
      outputs: {url: 'https://dev.example.com'}
    },
    'deploy (prod)': {result: 'skipped', outputs: {}}
  }

  const evalResult = evaluateResults(matrixNeeds)
  assert.equal(evalResult.passed, true)
  assert.equal(evalResult.total, 6)
  assert.deepEqual(evalResult.successes, [
    'filter',
    'test (18, ubuntu-24.04)',
    'test (20, ubuntu-24.04)',
    'deploy (dev)'
  ])
  assert.deepEqual(evalResult.skipped, [
    'test (22, ubuntu-24.04)',
    'deploy (prod)'
  ])
})

test('run: honors annotations=false toggle by suppressing ::error:: annotations', () => {
  const errors = []
  const mockLogger = {
    log: () => {},
    error: msg => errors.push(msg),
    warn: () => {}
  }

  const {exitCode, evaluation} = run({
    needsInput: JSON.stringify({
      failJob: {result: 'failure'}
    }),
    annotations: 'false',
    summary: 'false',
    logger: mockLogger
  })

  assert.equal(exitCode, 1)
  assert.equal(evaluation.passed, false)
  // No workflow annotations should have been emitted
  assert.equal(errors.length, 0)
})

test('run: honors summary=false toggle by skipping file write', () => {
  const tmpDir = fs.mkdtempSync(
    path.join(os.tmpdir(), 'workflow-results-no-summary-')
  )
  const summaryPath = path.join(tmpDir, 'summary.md')

  const {exitCode} = run({
    needsInput: JSON.stringify({
      job1: {result: 'success'}
    }),
    summary: 'false',
    summaryPath,
    logger: {log: () => {}, error: () => {}, warn: () => {}}
  })

  assert.equal(exitCode, 0)
  assert.equal(fs.existsSync(summaryPath), false)

  fs.rmSync(tmpDir, {recursive: true, force: true})
})

test('run: honors case-insensitive and boolean false toggles', () => {
  const errors = []
  const mockLogger = {
    log: () => {},
    error: msg => errors.push(msg),
    warn: () => {}
  }

  const tmpDir = fs.mkdtempSync(
    path.join(os.tmpdir(), 'workflow-results-toggles-')
  )
  const summaryPath = path.join(tmpDir, 'summary.md')

  // Test boolean false
  const run1 = run({
    needsInput: JSON.stringify({failJob: {result: 'failure'}}),
    annotations: false,
    summary: false,
    summaryPath,
    logger: mockLogger
  })
  assert.equal(run1.exitCode, 1)
  assert.equal(errors.length, 0)
  assert.equal(fs.existsSync(summaryPath), false)

  // Test "FALSE" and "False" strings
  const run2 = run({
    needsInput: JSON.stringify({failJob: {result: 'failure'}}),
    annotations: 'FALSE',
    summary: 'False',
    summaryPath,
    logger: mockLogger
  })
  assert.equal(run2.exitCode, 1)
  assert.equal(errors.length, 0)
  assert.equal(fs.existsSync(summaryPath), false)

  fs.rmSync(tmpDir, {recursive: true, force: true})
})

test('run: emits ::group:: and ::endgroup:: commands when running under GITHUB_ACTIONS', () => {
  const logs = []
  const mockLogger = {
    log: msg => logs.push(msg),
    error: () => {},
    warn: () => {}
  }

  const origAction = process.env.GITHUB_ACTIONS
  try {
    process.env.GITHUB_ACTIONS = 'true'
    const {exitCode} = run({
      needsInput: JSON.stringify({
        jobA: {result: 'success'}
      }),
      title: 'Rollup Group',
      summary: 'false',
      annotations: 'false',
      logger: mockLogger
    })

    assert.equal(exitCode, 0)
    assert.ok(logs.some(l => l === '::group::=== Rollup Group ==='))
    assert.ok(logs.some(l => l === '::endgroup::'))
  } finally {
    process.env.GITHUB_ACTIONS = origAction
  }
})

test('run: executes seamlessly when invoked purely via runner environment variables', () => {
  const tmpDir = fs.mkdtempSync(
    path.join(os.tmpdir(), 'workflow-results-env-test-')
  )
  const outputPath = path.join(tmpDir, 'output.txt')
  const summaryPath = path.join(tmpDir, 'summary.md')

  const origEnv = {...process.env}
  try {
    process.env.INPUT_NEEDS = JSON.stringify({
      ci: {result: 'success'},
      lint: {result: 'skipped'}
    })
    process.env.INPUT_TITLE = 'Native Runner Contract Test'
    process.env.INPUT_SUMMARY = 'true'
    process.env.INPUT_ANNOTATIONS = 'true'
    process.env.GITHUB_OUTPUT = outputPath
    process.env.GITHUB_STEP_SUMMARY = summaryPath

    const {exitCode, evaluation, markdown} = run()

    assert.equal(exitCode, 0)
    assert.equal(evaluation.passed, true)
    assert.ok(markdown.includes('### Native Runner Contract Test'))

    const summaryContent = fs.readFileSync(summaryPath, 'utf8')
    assert.ok(summaryContent.includes('### Native Runner Contract Test'))
    assert.ok(summaryContent.includes('| `ci` | ✅ Succeeded |'))
    assert.ok(summaryContent.includes('| `lint` | ⊘ Skipped |'))

    const outputContent = fs.readFileSync(outputPath, 'utf8')
    assert.ok(outputContent.includes('passed=true'))
    assert.ok(outputContent.includes('total=2'))
  } finally {
    process.env = origEnv
    fs.rmSync(tmpDir, {recursive: true, force: true})
  }
})

test('run: gracefully handles execution outside GitHub Actions when env vars are unset', () => {
  const logs = []
  const mockLogger = {
    log: msg => logs.push(msg),
    error: () => {},
    warn: () => {}
  }

  const {exitCode, evaluation} = run({
    needsInput: JSON.stringify({
      offlineJob: {result: 'success'}
    }),
    outputPath: undefined,
    summaryPath: undefined,
    logger: mockLogger
  })

  assert.equal(exitCode, 0)
  assert.equal(evaluation.passed, true)
  assert.ok(logs.some(l => l.includes('=== Workflow Results ===')))
})
