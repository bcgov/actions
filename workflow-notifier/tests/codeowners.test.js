'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { parse, ownersFor, select, SEARCH_ORDER } = require('../codeowners.js');

const rules = (t) => parse(t);

test('search order matches GitHub (.github first)', () => {
  assert.deepStrictEqual(SEARCH_ORDER.slice(0, 3), ['.github/CODEOWNERS', 'CODEOWNERS', 'docs/CODEOWNERS']);
});

test('last matching rule wins', () => {
  const r = rules('* @a\n/.github/workflows/ @b\n');
  assert.deepStrictEqual(ownersFor(r, 'src/app.js'), ['@a']);
  assert.deepStrictEqual(ownersFor(r, '.github/workflows/merge.yml'), ['@b']);
});

test('anchored, unanchored, extension and ** patterns', () => {
  const r = rules('*.js @js\n/docs/ @docs\nbuild/ @build\napps/**/test @t\n/README.md @readme\n');
  assert.deepStrictEqual(ownersFor(r, 'a/b/c.js'), ['@js']);
  assert.deepStrictEqual(ownersFor(r, 'docs/x/y.md'), ['@docs']);
  assert.strictEqual(ownersFor(r, 'sub/docs/y.md'), null);
  assert.deepStrictEqual(ownersFor(r, 'deep/build/out.txt'), ['@build']);
  assert.deepStrictEqual(ownersFor(r, 'apps/a/b/test/x'), ['@t']);
  assert.deepStrictEqual(ownersFor(r, 'apps/test/x'), ['@t']);
  assert.deepStrictEqual(ownersFor(r, 'README.md'), ['@readme']);
  assert.strictEqual(ownersFor(r, 'sub/README.md'), null);
});

test('single * does not cross directories when anchored', () => {
  const r = rules('/docs/* @d\n');
  assert.deepStrictEqual(ownersFor(r, 'docs/a.md'), ['@d']);
  assert.strictEqual(ownersFor(r, 'docs/sub/a.md'), null);
});

test('rule with no owners unsets ownership', () => {
  const r = rules('* @a\n/vendor/\n');
  assert.deepStrictEqual(ownersFor(r, 'vendor/x'), []);
});

test('comments are stripped, including mid-line', () => {
  const r = rules('# header\n* @a # @ghost\n');
  assert.deepStrictEqual(r, [{ pattern: '*', owners: ['@a'] }]);
  assert.deepStrictEqual(select('* @a # @ghost\n', 'all').users, ['a']);
});

test('all mode unions every handle', () => {
  const s = select('* @a @b\n/.github/ @c @A\n', 'all');
  assert.deepStrictEqual(s.users, ['a', 'b', 'c']);
});

test('paths mode unions last-match owners per path', () => {
  const text = '* @app1 @app2\n/.github/workflows/ @wf1 @wf2\n';
  assert.deepStrictEqual(select(text, 'paths', ['src/a.js']).users, ['app1', 'app2']);
  assert.deepStrictEqual(select(text, 'paths', ['.github/workflows/m.yml']).users, ['wf1', 'wf2']);
  assert.deepStrictEqual(select(text, 'paths', ['src/a.js', '.github/workflows/m.yml']).users, ['app1', 'app2', 'wf1', 'wf2']);
  assert.deepStrictEqual(select(text, 'paths', []).users, []);
});

test('team and email owners are separated, never users', () => {
  const s = select('* @bcgov/devops-team @alice dev@example.com\n', 'all');
  assert.deepStrictEqual(s.users, ['alice']);
  assert.deepStrictEqual(s.teams, ['bcgov/devops-team']);
  assert.strictEqual(s.emails, 1);
});
