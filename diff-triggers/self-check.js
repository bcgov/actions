#!/usr/bin/env node
/**
 * Minimal regression check: quoted filter paths must strip to bare pathspecs.
 * Fails loudly if the catastrophic silent-miss bug returns.
 */
const assert = require('assert');
const { parseFilters, stripQuotes } = require('./index.js');

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

console.log('diff-triggers self-check: ok');
