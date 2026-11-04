const test = require('node:test');
const assert = require('node:assert');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {
  InputError, RENAMED, assertKnownInputs, declaredInputs, givenInputs,
} = require('../inputs.js');

const root = path.join(__dirname, '..', '..');
const cli = path.join(__dirname, '..', 'inputs.js');
const builderYml = fs.readFileSync(path.join(root, 'builder', 'action.yml'), 'utf8');

test('declaredInputs: reads top-level input names only', () => {
  const names = declaredInputs(builderYml);
  assert.ok(names.includes('file') && names.includes('context') && names.includes('package'));
  assert.ok(!names.includes('build_file'));
  assert.ok(!names.includes('description') && !names.includes('default'));
  assert.deepStrictEqual(declaredInputs('name: x\ninputs:\n  a:\n    description: A\n  "b c":\n    default: 1\noutputs:\n  z:\n'), ['a', 'b c']);
});

test('assertKnownInputs: declared inputs pass, in any case', () => {
  assert.doesNotThrow(() => assertKnownInputs('builder', ['package', 'FILE'], declaredInputs(builderYml)));
});

test('assertKnownInputs: renamed input fails and names the replacement', () => {
  assert.throws(
    () => assertKnownInputs('builder', ['package', 'build_file', 'build_context'], declaredInputs(builderYml)),
    e => e instanceof InputError
      && e.message.startsWith('::error title=builder: unknown input::')
      && e.message.includes('build_file: renamed to file')
      && e.message.includes('build_context: renamed to context')
      && e.message.includes('docs/MIGRATION.md')
      && e.message.includes('builder/README.md'),
  );
  assert.throws(
    () => assertKnownInputs('image-tracker', ['package'], ['packages']),
    /package: renamed to packages/,
  );
});

test('assertKnownInputs: unknown input fails and names the key', () => {
  assert.throws(
    () => assertKnownInputs('builder', ['not_a_thing'], declaredInputs(builderYml)),
    e => e instanceof InputError && e.message.includes('not_a_thing: not an input of builder'),
  );
  assert.throws(() => assertKnownInputs('builder', ['sbom'], declaredInputs(builderYml)), /sbom: removed/);
});

test('rename map: every replacement is a declared input of that action', () => {
  for (const [action, map] of Object.entries(RENAMED)) {
    const declared = declaredInputs(fs.readFileSync(path.join(root, action, 'action.yml'), 'utf8'));
    for (const [old, now] of Object.entries(map)) {
      assert.ok(!declared.includes(old), `${action}: ${old} is still declared`);
      if (now) assert.ok(declared.includes(now), `${action}: ${now} is not declared`);
    }
  }
});

test('givenInputs: INPUTS_JSON wins, else INPUT_* env', () => {
  assert.deepStrictEqual(givenInputs({ INPUTS_JSON: '{"a":"1","build_file":"x"}', INPUT_Z: '1' }), ['a', 'build_file']);
  assert.deepStrictEqual(givenInputs({ INPUT_BUILD_FILE: 'x', PATH: '/' }), ['build_file']);
});

test('CLI assert-known: fails non-zero with ::error:: on a renamed input', () => {
  const r = spawnSync('node', [cli, 'assert-known', path.join(root, 'builder')], {
    env: { PATH: process.env.PATH, INPUTS_JSON: JSON.stringify({ package: 'x', build_file: 'Dockerfile' }) },
    encoding: 'utf8',
  });
  assert.strictEqual(r.status, 1);
  assert.match(r.stderr, /::error title=builder: unknown input::.*build_file: renamed to file/);
});

test('CLI assert-known: passes for declared inputs (node action env form)', () => {
  const r = spawnSync('node', [cli, 'assert-known', path.join(root, 'image-tracker')], {
    env: { PATH: process.env.PATH, INPUT_PACKAGES: 'a', INPUT_TOKEN: 't' },
    encoding: 'utf8',
  });
  assert.strictEqual(r.status, 0, r.stderr);
});

test('node action entry fails on a renamed input', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ak-'));
  const r = spawnSync('node', [path.join(root, 'image-tracker', 'index.js')], {
    cwd: dir,
    env: { PATH: process.env.PATH, INPUT_PACKAGE: 'backend' },
    encoding: 'utf8',
  });
  assert.strictEqual(r.status, 1);
  assert.match(r.stdout, /package: renamed to packages/);
});
