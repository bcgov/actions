const test = require('node:test');
const assert = require('node:assert');
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const fs = require('node:fs');

const index = path.join(__dirname, '..', 'index.js');

test('missing markdown fails', () => {
  const r = spawnSync(process.execPath, [index], { env: { PATH: process.env.PATH }, encoding: 'utf8' });
  assert.strictEqual(r.status, 1);
  assert.match(r.stdout, /markdown is required/);
});
test('no PR outside pull_request fails with a clear error', () => {
  const r = spawnSync(process.execPath, [index], { env: { PATH: process.env.PATH, INPUT_MARKDOWN: 'x' }, encoding: 'utf8' });
  assert.strictEqual(r.status, 1);
  assert.match(r.stdout, /Set the pr input/);
});
test('action.yml is a node24 action with markdown required and no debug input', () => {
  const yml = fs.readFileSync(path.join(__dirname, '..', 'action.yml'), 'utf8');
  assert.match(yml, /using: 'node24'/);
  assert.match(yml, /main: 'index.js'/);
  assert.match(yml, /markdown:\n\s+description:[^\n]*\n\s+required: true/);
  assert.doesNotMatch(yml, /debug|add_markdown/);
});
test('pr-validate points at the shared script', () => {
  const yml = fs.readFileSync(path.join(__dirname, '..', '..', 'pr-validate', 'action.yml'), 'utf8');
  assert.match(yml, /\.\.\/shared\/pr-description\.js/);
});
