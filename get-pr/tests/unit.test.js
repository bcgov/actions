const test = require('node:test')
const assert = require('node:assert')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const {spawnSync, execFileSync} = require('node:child_process')

const ACTION = path.join(__dirname, '..', 'index.js')

// Runs index.js offline: no token, so the API tiers are skipped
function run(eventName, payload, {cwd, env = {}} = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'get-pr-'))
  const eventPath = path.join(dir, 'event.json')
  const outputPath = path.join(dir, 'output')
  fs.writeFileSync(eventPath, JSON.stringify(payload))
  fs.writeFileSync(outputPath, '')
  const childEnv = {...process.env, ...env}
  delete childEnv.GITHUB_TOKEN
  delete childEnv.INPUT_GITHUB_TOKEN
  const res = spawnSync('node', [ACTION], {
    cwd: cwd || dir,
    encoding: 'utf8',
    env: {
      ...childEnv,
      TEST_EVENT_NAME: eventName,
      TEST_EVENT_PATH: eventPath,
      TEST_REPOSITORY: 'bcgov/example',
      TEST_SHA: 'abc123',
      GITHUB_OUTPUT: outputPath
    }
  })
  return {status: res.status, output: fs.readFileSync(outputPath, 'utf8')}
}

function repoWithCommit(subject) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'get-pr-git-'))
  const git = (...args) => execFileSync('git', ['-C', dir, ...args])
  git('init', '-q')
  git(
    '-c',
    'user.name=t',
    '-c',
    'user.email=t@t',
    'commit',
    '-q',
    '--allow-empty',
    '-m',
    subject
  )
  return dir
}

test('pull_request: number from payload', () => {
  const r = run('pull_request', {pull_request: {number: 42}})
  assert.strictEqual(r.status, 0)
  assert.strictEqual(r.output, 'pr=42\n')
})

test('pull_request: top-level number fallback', () => {
  const r = run('pull_request', {number: 7})
  assert.strictEqual(r.status, 0)
  assert.strictEqual(r.output, 'pr=7\n')
})

test('merge_group: current queue ref format', () => {
  const r = run('merge_group', {
    merge_group: {head_ref: 'refs/heads/gh-readonly-queue/main/pr-123-0123abcd'}
  })
  assert.strictEqual(r.status, 0)
  assert.strictEqual(r.output, 'pr=123\n')
})

test('merge_group: old queue ref format', () => {
  const r = run('merge_group', {merge_group: {head_ref: 'queue/main/pr-55'}})
  assert.strictEqual(r.status, 0)
  assert.strictEqual(r.output, 'pr=55\n')
})

test('push: squash subject from local git history', () => {
  const cwd = repoWithCommit('feat: thing (#88)')
  const r = run('push', {after: 'abc123'}, {cwd})
  assert.strictEqual(r.status, 0)
  assert.strictEqual(r.output, 'pr=88\n')
})

test('release: merge commit subject from local git history', () => {
  const cwd = repoWithCommit('Merge pull request #19 from bcgov/feat/x')
  const r = run('release', {}, {cwd})
  assert.strictEqual(r.status, 0)
  assert.strictEqual(r.output, 'pr=19\n')
})

test('workflow_dispatch: general PR mention from local git history', () => {
  const cwd = repoWithCommit('chore: follow-up to PR #31')
  const r = run('workflow_dispatch', {}, {cwd})
  assert.strictEqual(r.status, 0)
  assert.strictEqual(r.output, 'pr=31\n')
})

test('push: no PR found fails', () => {
  const cwd = repoWithCommit('chore: direct push')
  const r = run('push', {after: 'abc123'}, {cwd})
  assert.strictEqual(r.status, 1)
  assert.strictEqual(r.output, '')
})

test('issues: ignored title exits 0 with no output', () => {
  const r = run('issues', {issue: {title: 'Dependency Dashboard'}})
  assert.strictEqual(r.status, 0)
  assert.strictEqual(r.output, '')
})

test('issues: other title fails', () => {
  const r = run('issues', {issue: {title: 'Bug report'}})
  assert.strictEqual(r.status, 1)
})

test('unknown event fails', () => {
  const r = run('schedule', {})
  assert.strictEqual(r.status, 1)
  assert.strictEqual(r.output, '')
})
