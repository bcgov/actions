const test = require('node:test');
const assert = require('node:assert');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { InputError, actionRepo, assertKnownInputs, declaredInputs, jsonKeys } = require('../enforce.js');

const root = path.join(__dirname, '..', '..');
const cli = path.join(__dirname, '..', 'enforce.js');
const entry = path.join(__dirname, '..', 'index.js');
const builderYml = fs.readFileSync(path.join(root, 'builder', 'action.yml'), 'utf8');
const node = (file, args, env, cwd) =>
  spawnSync('node', [file, ...args], { cwd, env: { PATH: process.env.PATH, ...env }, encoding: 'utf8' });

test('declaredInputs: reads top-level input names only', () => {
  const names = declaredInputs(builderYml);
  assert.ok(names.includes('file') && names.includes('context') && names.includes('package'));
  assert.ok(!names.includes('build_file') && !names.includes('description'));
  assert.deepStrictEqual(declaredInputs('name: x\ninputs:\n  a:\n    description: A\n  "b c":\n    default: 1\noutputs:\n  z:\n'), ['a', 'b c']);
});

test('assertKnownInputs: declared inputs pass, in any case', () => {
  assert.doesNotThrow(() => assertKnownInputs('builder', ['package', 'FILE'], declaredInputs(builderYml)));
});

test('assertKnownInputs: undeclared inputs fail, naming each key, the inputs and README', () => {
  assert.throws(
    () => assertKnownInputs('builder', ['package', 'build_file', 'build_context'], declaredInputs(builderYml)),
    e => e instanceof InputError
      && e.message.startsWith('::error title=builder: unknown input::Unknown input(s) for builder: build_file, build_context')
      && e.message.includes('build_file: not an input of builder')
      && e.message.includes('Inputs: package, context, file')
      && e.message.includes('https://github.com/bcgov/actions/blob/main/builder/README.md'),
  );
});

test('assertKnownInputs: composite (raw) keys fold case but not spaces', () => {
  const declared = declaredInputs(builderYml);
  assert.doesNotThrow(() => assertKnownInputs('builder', ['BUILD_ARGS', 'package'], declared, { raw: true }));
  assert.throws(() => assertKnownInputs('builder', ['build args'], declared, { raw: true }), /build args: not an input of builder/);
  // Node INPUT_* env names keep space -> _ as the runner sets them
  assert.doesNotThrow(() => assertKnownInputs('builder', ['build args'], declared));
});

test('actionRepo: runner action path, else the workflow repo', () => {
  assert.strictEqual(actionRepo('/home/runner/work/_actions/bcgov/actions-openshift/abc123/deployer'), 'bcgov/actions-openshift');
  assert.strictEqual(actionRepo('/tmp/x', { GITHUB_REPOSITORY: 'o/r' }), 'o/r');
});

test('jsonKeys: object keys, clear error otherwise', () => {
  assert.deepStrictEqual(jsonKeys('{"a":"1","b c":""}'), ['a', 'b c']);
  assert.throws(() => jsonKeys('nope'), /toJSON\(inputs\)/);
  assert.throws(() => jsonKeys('[]'), /JSON object/);
});

test('every action: declared inputs pass, an extra key fails with the diagnostic', () => {
  const dirs = fs.readdirSync(root).filter(d => fs.existsSync(path.join(root, d, 'action.yml')));
  assert.ok(dirs.length > 5);
  for (const d of dirs) {
    const o = {};
    for (const k of declaredInputs(fs.readFileSync(path.join(root, d, 'action.yml'), 'utf8'))) o[k] = 'x';
    assert.strictEqual(node(cli, [path.join(root, d), JSON.stringify(o)]).status, 0, d);
    const r = node(cli, [path.join(root, d), JSON.stringify({ ...o, not_an_input: 'x' })]);
    assert.strictEqual(r.status, 1, d);
    assert.match(r.stdout, new RegExp(`Unknown input\\(s\\) for ${d}: not_an_input%0A  not_an_input: not an input of ${d}`), d);
  }
});

test('action entry (index.js): reads INPUT_INPUTS / INPUT_ACTION_PATH', () => {
  const dir = path.join(root, 'builder');
  const ok = node(entry, [], { INPUT_INPUTS: JSON.stringify({ package: 'x' }), INPUT_ACTION_PATH: dir });
  assert.strictEqual(ok.status, 0, ok.stdout);
  const bad = node(entry, [], { INPUT_INPUTS: JSON.stringify({ package: 'x', 'build args': 'A=1' }), INPUT_ACTION_PATH: dir });
  assert.strictEqual(bad.status, 1);
  assert.match(bad.stdout, /::error title=builder: unknown input::.*build args: not an input of builder/);
  assert.match(node(entry, [], { INPUT_INPUTS: '{}' }).stdout, /action_path is required/);
});

test('node action entry fails on an undeclared input', () => {
  const r = node(path.join(root, 'image-tracker', 'index.js'), [], { INPUT_PACKAGE: 'backend' }, fs.mkdtempSync(path.join(os.tmpdir(), 'ie-')));
  assert.strictEqual(r.status, 1);
  assert.match(r.stdout, /package: not an input of image-tracker/);
});
