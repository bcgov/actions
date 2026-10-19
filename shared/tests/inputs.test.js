const test = require('node:test');
const assert = require('node:assert');
const { execFileSync, spawnSync } = require('node:child_process');
const path = require('node:path');
const {
  InputError, getInput, getToken, isDebug, parseBool, parseEnum, parseList,
} = require('../inputs.js');

const cli = path.join(__dirname, '..', 'inputs.js');

test('parseList: multiline, comma, JSON, single', () => {
  assert.deepStrictEqual(parseList('a/\n\n b/ \n'), ['a/', 'b/']);
  assert.deepStrictEqual(parseList('a, b,c'), ['a', 'b', 'c']);
  assert.deepStrictEqual(parseList('src/{a,b}/**, c/'), ['src/{a,b}/**', 'c/']);
  assert.deepStrictEqual(parseList('src/{a,b}/**\nc/'), ['src/{a,b}/**', 'c/']);
  assert.deepStrictEqual(parseList('["a", "b"]'), ['a', 'b']);
  assert.deepStrictEqual(parseList("'a/**'"), ['a/**']);
  assert.deepStrictEqual(parseList('"my path/"'), ['my path/']);
  assert.deepStrictEqual(parseList(''), []);
});

test('parseList: legacy formats throw the before/after error', () => {
  for (const raw of ["('a/' 'b/')", 'a b', 'a;b', "'a' 'b'", 'a b, c']) {
    assert.throws(() => parseList(raw, 'triggers'), InputError, raw);
  }
  try {
    parseList("('backend/' 'frontend/')", 'triggers');
  } catch (e) {
    const lines = e.message.split('%0A');
    assert.match(lines[0], /Invalid triggers input: \('backend\/' 'frontend\/'\)/);
    assert.match(lines[1], /parenthesized lists are no longer supported/);
    assert.ok(lines.includes('  triggers: |'));
    assert.ok(lines.includes('    frontend/'));
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
  const env = { ...process.env, INPUT_PACKAGES: 'a, b', INPUT_DRY_RUN: 'TRUE', INPUT_MODE: '' };
  assert.strictEqual(execFileSync('node', [cli, 'list', 'packages'], { env }).toString(), 'a\nb\n');
  assert.strictEqual(execFileSync('node', [cli, 'bool', 'dry_run'], { env }).toString(), 'true\n');
  assert.strictEqual(execFileSync('node', [cli, 'enum', 'mode', 'a,b', 'b'], { env }).toString(), 'b\n');
  const bad = spawnSync('node', [cli, 'list', 'packages'], { env: { ...env, INPUT_PACKAGES: '(a b)' } });
  assert.strictEqual(bad.status, 1);
  assert.match(bad.stderr.toString(), /Invalid packages input/);
});
