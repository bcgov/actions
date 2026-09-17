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

test('evaluateResults: catches cancelled (double-l) and canceled (single-l)', () => {
  const needs1 = {
    lint: {result: 'cancelled'}
  }
  const eval1 = evaluateResults(needs1)
  assert.equal(eval1.passed, false)
  assert.deepEqual(eval1.cancelled, ['lint'])

  const needs2 = {
    lint: {result: 'canceled'}
  }
  const eval2 = evaluateResults(needs2)
  assert.equal(eval2.passed, false)
  assert.deepEqual(eval2.cancelled, ['lint'])
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
      deploy: {result: 'canceled'}
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
