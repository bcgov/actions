const test = require('node:test');
const assert = require('node:assert');
const { execFileSync, spawnSync } = require('node:child_process');
const path = require('node:path');
const {
  InputError, getInput, getToken, isDebug, parseBool, parseEnum, parseList,
} = require('../inputs.js');

const cli = path.join(__dirname, '..', 'inputs.js');

test('parseList: one item per line, or a single value', () => {
  assert.deepStrictEqual(parseList('a/\n\n b/ \n'), ['a/', 'b/']);
  assert.deepStrictEqual(parseList('src/{a,b}/**\nc/'), ['src/{a,b}/**', 'c/']);
  assert.deepStrictEqual(parseList('src/{a,b}/**'), ['src/{a,b}/**']);
  assert.deepStrictEqual(parseList('backend'), ['backend']);
  assert.deepStrictEqual(parseList("'a/**'"), ['a/**']);
  assert.deepStrictEqual(parseList('"my path/"\n"other path/"'), ['my path/', 'other path/']);
  assert.deepStrictEqual(parseList(''), []);
});

test('parseList: other formats throw the format error', () => {
  for (const raw of [
    "('a/' 'b/')", 'a b', 'a;b', "'a' 'b'", 'a b, c', 'a, b', 'a,b', '"backend/", "frontend/"',
    '["a", "b"]', '["backend/",]', "(\n'backend/'\n'frontend/'\n)", 'a/\nb/, c/', 'a/\nb/ c/',
  ]) {
    assert.throws(() => parseList(raw, 'triggers'), InputError, raw);
  }
  try {
    parseList('backend/, frontend/', 'triggers');
    assert.fail('expected an InputError');
  } catch (e) {
    const lines = e.message.split('%0A');
    assert.match(lines[0], /Invalid triggers input: backend\/, frontend\//);
    assert.strictEqual(lines[1], 'triggers takes one item per line, or a single value.');
    assert.ok(lines.includes('  triggers: |'));
    assert.ok(lines.includes('    backend/'));
    assert.ok(lines.includes('    frontend/'));
    assert.ok(lines.at(-1).includes('https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idstepswith'));
  }
});

test('parseBool and parseEnum', () => {
  assert.strictEqual(parseBool('TRUE', 'x'), true);
  assert.strictEqual(parseBool('false', 'x', true), false);
  assert.strictEqual(parseBool('', 'x', true), true);
  assert.throws(() => parseBool('yes', 'x'), InputError);
  assert.strictEqual(parseEnum('Always', 'x', ['always', 'never'], 'never'), 'always');
  assert.strictEqual(parseEnum('', 'x', ['always', 'never'], 'never'), 'never');
  assert.throws(() => parseEnum('true', 'x', ['always', 'never'], 'never'), InputError);
});

test('getInput, getToken, isDebug', () => {
  assert.strictEqual(getInput('dry run', { INPUT_DRY_RUN: ' x ' }), 'x');
  assert.strictEqual(getToken({ INPUT_TOKEN: 'a', GITHUB_TOKEN: 'b' }), 'a');
  assert.strictEqual(getToken({ GITHUB_TOKEN: 'b' }), 'b');
  assert.strictEqual(isDebug({ INPUT_DEBUG: 'true' }), true);
  assert.strictEqual(isDebug({ RUNNER_DEBUG: '1' }), true);
  assert.strictEqual(isDebug({}), false);
});

test('CLI for composite actions', () => {
  const env = { ...process.env, INPUT_PACKAGES: 'a\nb', INPUT_DRY_RUN: 'TRUE', INPUT_MODE: '' };
  assert.strictEqual(execFileSync('node', [cli, 'list', 'packages'], { env }).toString(), 'a\nb\n');
  assert.strictEqual(execFileSync('node', [cli, 'bool', 'dry_run'], { env }).toString(), 'true\n');
  assert.strictEqual(execFileSync('node', [cli, 'enum', 'mode', 'a,b', 'b'], { env }).toString(), 'b\n');
  assert.strictEqual(execFileSync('node', [cli, 'token'], { env: { ...env, INPUT_TOKEN: ' ', GITHUB_TOKEN: 'gh' } }).toString(), 'gh\n');
  const bad = spawnSync('node', [cli, 'list', 'packages'], { env: { ...env, INPUT_PACKAGES: 'a, b' } });
  assert.strictEqual(bad.status, 1);
  assert.match(bad.stderr.toString(), /Invalid packages input/);
});
