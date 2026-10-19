#!/usr/bin/env node
/**
 * Minimal regression check: quoted filter paths must strip to bare pathspecs.
 * Fails loudly if the catastrophic silent-miss bug returns.
 */
const assert = require('assert');
const { legacyTriggersMessage, parseFilters, parseTriggers, stripQuotes } = require('./index.js');

assert.strictEqual(stripQuotes("'diff-triggers/**'"), 'diff-triggers/**');
assert.strictEqual(stripQuotes('"builder-ghcr/**"'), 'builder-ghcr/**');
assert.strictEqual(stripQuotes('unquoted/**'), 'unquoted/**');

const filters = parseFilters(`
diff-triggers:
  - 'diff-triggers/**'
  - ".github/workflows/test-diff-triggers.yml"
workflows:
  - '.github/workflows/**'
`);

assert.deepStrictEqual(filters['diff-triggers'], [
  'diff-triggers/**',
  '.github/workflows/test-diff-triggers.yml',
]);
assert.deepStrictEqual(filters.workflows, ['.github/workflows/**']);

// Patterns must not retain quote characters (the false-green bug).
for (const paths of Object.values(filters)) {
  for (const p of paths) {
    assert.ok(!p.startsWith("'") && !p.startsWith('"'), `quoted path survived: ${p}`);
  }
}

// Inline non-JSON [a, b] must not leak brackets into pathspecs.
const inline = parseFilters('frontend: [frontend/, backend/]\n');
assert.deepStrictEqual(inline.frontend, ['frontend/', 'backend/']);
for (const p of inline.frontend) {
  assert.ok(!p.includes('[') && !p.includes(']'), `bracket leaked into pathspec: ${p}`);
}

// Reserved output keys ('triggered', 'changes') must throw an error.
assert.throws(() => {
  parseFilters('triggered: [foo/]\n');
}, /Filter name 'triggered' is reserved/);

assert.throws(() => {
  parseFilters('changes: [bar/]\n');
}, /Filter name 'changes' is reserved/);

// parseTriggers: supported formats
assert.deepStrictEqual(parseTriggers('frontend/\nbackend/'), ['frontend/', 'backend/']);
assert.deepStrictEqual(parseTriggers('["frontend/", "backend/"]'), ['frontend/', 'backend/']);
assert.deepStrictEqual(parseTriggers('frontend/'), ['frontend/']);
assert.deepStrictEqual(parseTriggers('"my path/"'), ['my path/']);

// parseTriggers: legacy formats must fail
function expectLegacyFail(raw) {
  let exitCode = 0;
  const origExit = process.exit;
  const origErr = console.error;
  console.error = () => {};
  process.exit = (code) => {
    exitCode = code;
    throw new Error('exit');
  };
  try {
    parseTriggers(raw);
    assert.fail(`expected legacy reject for: ${raw}`);
  } catch (e) {
    if (e.message !== 'exit') throw e;
    assert.strictEqual(exitCode, 1, `expected exit 1 for: ${raw}`);
  } finally {
    process.exit = origExit;
    console.error = origErr;
  }
}
expectLegacyFail("('frontend/' 'backend/')");
expectLegacyFail('frontend/,backend/');
expectLegacyFail('frontend/;backend/');
expectLegacyFail('frontend/ backend/');

// Legacy error must name the bad value and show the converted multiline form.
const msg = legacyTriggersMessage("('backend/' 'frontend/')").split('%0A');
assert.ok(msg[0].startsWith('::error '), 'must be an error annotation');
assert.ok(msg[0].includes("Invalid triggers input: ('backend/' 'frontend/')"), 'must name the bad value');
assert.ok(msg[1].includes('parenthesized lists are no longer supported'), 'must say parens are unsupported');
assert.ok(msg.includes("  triggers: ('backend/' 'frontend/')"), 'must show before');
const after = msg.indexOf('  triggers: |');
assert.ok(after > 0, 'must show after');
assert.deepStrictEqual(msg.slice(after + 1, after + 3), ['    backend/', '    frontend/']);
assert.ok(msg.includes(`Or: triggers: '["backend/","frontend/"]'`), 'must show JSON form');
const comma = legacyTriggersMessage('backend/,frontend/').split('%0A');
assert.ok(comma[1].startsWith('Comma, semicolon or space separated'));
assert.deepStrictEqual(comma.slice(comma.indexOf('  triggers: |') + 1, -2), ['    backend/', '    frontend/']);

assert.ok(msg.includes('Migration guide: https://github.com/bcgov/actions/blob/main/MIGRATION.md#triggers'), 'must link the guide');

console.log('diff-triggers self-check: ok');
