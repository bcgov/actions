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

test('escaped spaces stay in the pattern', () => {
  const r = rules('* @a\n/My\\ Folder/ @b\n');
  assert.strictEqual(r[1].pattern, '/My Folder/');
  assert.deepStrictEqual(ownersFor(r, 'My Folder/app.js'), ['@b']);
});

test('escaped leading hash is a literal pattern', () => {
  const r = rules('\\#notes @a\n');
  assert.deepStrictEqual(ownersFor(r, '#notes'), ['@a']);
});

test('? matches exactly one character within a segment', () => {
  const r = rules('/file?.txt @q\n');
  assert.deepStrictEqual(ownersFor(r, 'file1.txt'), ['@q']);
  assert.strictEqual(ownersFor(r, 'file.txt'), null);
  assert.strictEqual(ownersFor(r, 'file12.txt'), null);
  assert.strictEqual(ownersFor(rules('/a?b @q\n'), 'a/b'), null);
});

test('trailing / owns every child, at any depth', () => {
  const r = rules('/apps/ @apps\n');
  assert.deepStrictEqual(ownersFor(r, 'apps/x.js'), ['@apps']);
  assert.deepStrictEqual(ownersFor(r, 'apps/a/b/c.js'), ['@apps']);
  assert.strictEqual(ownersFor(r, 'apps'), null);
  assert.strictEqual(ownersFor(r, 'apps-old/x.js'), null);
});

test('unanchored name matches at any depth, file or directory', () => {
  const r = rules('logs @l\n');
  assert.deepStrictEqual(ownersFor(r, 'logs'), ['@l']);
  assert.deepStrictEqual(ownersFor(r, 'a/b/logs'), ['@l']);
  assert.deepStrictEqual(ownersFor(r, 'a/logs/x.txt'), ['@l']);
  assert.strictEqual(ownersFor(r, 'a/mylogs/x.txt'), null);
});

test('mid-path slash anchors to the repo root', () => {
  const r = rules('docs/api @d\n');
  assert.deepStrictEqual(ownersFor(r, 'docs/api/x.md'), ['@d']);
  assert.strictEqual(ownersFor(r, 'src/docs/api/x.md'), null);
  // GitHub example: `apps/` (trailing only) is unanchored
  assert.deepStrictEqual(ownersFor(rules('apps/ @o\n'), 'nested/apps/x'), ['@o']);
});

test('** leading, trailing and middle forms', () => {
  assert.deepStrictEqual(ownersFor(rules('**/logs @l\n'), 'deep/a/logs/x'), ['@l']);
  assert.deepStrictEqual(ownersFor(rules('/build/** @b\n'), 'build/a/b.o'), ['@b']);
  assert.deepStrictEqual(ownersFor(rules('/a/**/b @m\n'), 'a/b'), ['@m']);
  assert.deepStrictEqual(ownersFor(rules('/a/**/b @m\n'), 'a/x/y/b'), ['@m']);
  assert.strictEqual(ownersFor(rules('/a/**/b @m\n'), 'x/a/b'), null);
});

test('overlapping last-match stack: only the final match counts', () => {
  const text = [
    '* @all',
    '*.js @js',
    '/src/ @src',
    '/src/**/*.test.js @tests',
    '/src/vendor/',
    '/src/vendor/keep.js @keep',
  ].join('\n');
  const r = rules(text);
  assert.deepStrictEqual(ownersFor(r, 'README.md'), ['@all']);
  assert.deepStrictEqual(ownersFor(r, 'lib/x.js'), ['@js']);
  assert.deepStrictEqual(ownersFor(r, 'src/x.js'), ['@src']);
  assert.deepStrictEqual(ownersFor(r, 'src/a/x.test.js'), ['@tests']);
  assert.deepStrictEqual(ownersFor(r, 'src/vendor/lib.test.js'), []);
  assert.deepStrictEqual(ownersFor(r, 'src/vendor/keep.js'), ['@keep']);
  assert.deepStrictEqual(select(text, 'paths', ['src/vendor/lib.js', 'src/x.js']).users, ['src']);
});

test('empty owner after a more specific match unsets it', () => {
  const r = rules('/docs/ @docs\n/docs/*.md @md\n/docs/draft.md\n');
  assert.deepStrictEqual(ownersFor(r, 'docs/draft.md'), []);
  assert.deepStrictEqual(ownersFor(r, 'docs/a.md'), ['@md']);
  assert.deepStrictEqual(select('* @a\n/docs/draft.md\n', 'paths', ['docs/draft.md']).users, []);
});

test('weird but legal owner mixes', () => {
  const s = select('* @Org/Team-1 @a-b @A-B user.name+tag@example.co.uk @bcgov/x @c\t@d\n', 'all');
  assert.deepStrictEqual(s.users, ['a-b', 'c', 'd']);
  assert.deepStrictEqual(s.teams, ['Org/Team-1', 'bcgov/x']);
  assert.strictEqual(s.emails, 1);
  // Not a GitHub owner form: dropped, never assigned
  assert.deepStrictEqual(select('* @-bad bare @a\n', 'all').users, ['a']);
});

test('CRLF files and leading ./ paths', () => {
  const r = rules('* @a\r\n/src/ @b\r\n');
  assert.deepStrictEqual(ownersFor(r, './src/x.js'), ['@b']);
  assert.deepStrictEqual(ownersFor(r, '/src/x.js'), ['@b']);
});

test('! negation is not supported and never pretends to be', () => {
  const r = rules('* @a\n!/docs/ @neg\n');
  // Treated as a literal pattern: docs/ keeps @a, only a path literally named `!/docs/...` matches
  assert.deepStrictEqual(ownersFor(r, 'docs/x.md'), ['@a']);
  assert.deepStrictEqual(ownersFor(r, '!/docs/x.md'), ['@neg']);
});

test('[] character ranges are not supported and never pretend to be', () => {
  const r = rules('/file[0-9].txt @r\n');
  assert.strictEqual(ownersFor(r, 'file1.txt'), null);
  assert.deepStrictEqual(ownersFor(r, 'file[0-9].txt'), ['@r']);
});
