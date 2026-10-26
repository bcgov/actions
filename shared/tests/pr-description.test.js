const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { alreadyPresent, appendBody, normalizeText, resolvePr, run } = require('../pr-description.js');

test('normalizeText trims line ends and CRLF', () => {
  assert.strictEqual(normalizeText(' a  \r\nb\r\n'), 'a\nb');
});
test('checkbox state does not count as different', () => {
  assert.ok(alreadyPresent('intro\n\n- [x] done', '- [ ] done'));
  assert.ok(!alreadyPresent('intro', '- [ ] done'));
});
test('appendBody separates with a blank line', () => {
  assert.strictEqual(appendBody('body\n', 'md'), 'body\n\nmd');
  assert.strictEqual(appendBody('', 'md'), 'md');
});

test('resolvePr: input wins, accepts #N, rejects junk', () => {
  assert.deepStrictEqual(resolvePr('42', { pull_request: { number: 1 } }), { number: 42, fork: false });
  assert.strictEqual(resolvePr('#7', {}).number, 7);
  assert.ok(resolvePr('abc', {}).error);
});
test('resolvePr: pull_request event, fork flagged', () => {
  assert.deepStrictEqual(resolvePr('', { pull_request: { number: 3, head: { repo: { fork: true } } } }), { number: 3, fork: true });
});
test('resolvePr: explicit pr matching fork event PR keeps fork flag', () => {
  const ev = { pull_request: { number: 3, head: { repo: { fork: true } } } };
  assert.deepStrictEqual(resolvePr('3', ev), { number: 3, fork: true });
  assert.deepStrictEqual(resolvePr('#3', ev), { number: 3, fork: true });
  assert.deepStrictEqual(resolvePr('9', ev), { number: 9, fork: false });
});
test('resolvePr: issue_comment on a PR and workflow_run', () => {
  assert.strictEqual(resolvePr('', { issue: { number: 5, pull_request: {} } }).number, 5);
  assert.ok(resolvePr('', { issue: { number: 5 } }).error, 'plain issue is not a PR');
  assert.strictEqual(resolvePr('', { workflow_run: { pull_requests: [{ number: 9 }] } }).number, 9);
});
test('resolvePr: push event without pr fails clearly', () => {
  assert.match(resolvePr('', { ref: 'refs/heads/main' }).error, /Set the pr input/);
});

function envFor(event, extra = {}) {
  const p = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'prd-')), 'event.json');
  fs.writeFileSync(p, JSON.stringify(event));
  return { GITHUB_EVENT_PATH: p, GITHUB_REPOSITORY: 'o/r', GITHUB_API_URL: 'https://api.test', INPUT_TOKEN: 't', ...extra };
}
function fakeFetch(body) {
  const calls = [];
  const fn = async (url, opts = {}) => {
    calls.push({ url, ...opts });
    return { ok: true, status: 200, json: async () => ({ body }) };
  };
  fn.calls = calls;
  return fn;
}

test('run: push event with pr input PATCHes once', async () => {
  const f = fakeFetch('old');
  const code = await run(envFor({ ref: 'refs/heads/main' }, { INPUT_MARKDOWN: 'deployed', INPUT_PR: '12' }), f);
  assert.strictEqual(code, 0);
  assert.strictEqual(f.calls.length, 2);
  assert.strictEqual(f.calls[1].url, 'https://api.test/repos/o/r/pulls/12');
  assert.strictEqual(JSON.parse(f.calls[1].body).body, 'old\n\ndeployed');
});
test('run: already present makes no PATCH', async () => {
  const f = fakeFetch('x\n\ndeployed');
  assert.strictEqual(await run(envFor({ pull_request: { number: 1 } }, { INPUT_MARKDOWN: 'deployed' }), f), 0);
  assert.strictEqual(f.calls.length, 1);
});
test('run: no PR resolvable exits 1 without calls', async () => {
  const f = fakeFetch('');
  assert.strictEqual(await run(envFor({}, { INPUT_MARKDOWN: 'x' }), f), 1);
  assert.strictEqual(f.calls.length, 0);
});
test('run: fork PR is a no-op', async () => {
  const f = fakeFetch('');
  const ev = { pull_request: { number: 2, head: { repo: { fork: true } } } };
  assert.strictEqual(await run(envFor(ev, { INPUT_MARKDOWN: 'x' }), f), 0);
  assert.strictEqual(f.calls.length, 0);
});
test('run: empty markdown is a no-op (pr-validate default)', async () => {
  const f = fakeFetch('');
  assert.strictEqual(await run(envFor({}, {}), f), 0);
  assert.strictEqual(f.calls.length, 0);
});
