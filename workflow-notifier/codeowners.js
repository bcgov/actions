'use strict';
/**
 * CODEOWNERS parsing and matching for workflow-notifier.
 *
 * Follows GitHub's rules: the last matching pattern wins, `#` starts a
 * comment (also mid-line), patterns use gitignore-style globs without `!`
 * or `[]`. Team owners (`@org/team`) and email owners are returned
 * separately so the caller can skip them; only `@user` handles become
 * assignees.
 *
 * CLI: node codeowners.js <codeowners-file> <all|paths>
 *   `paths` reads newline-separated repo paths from stdin.
 * Prints three lines: `users=a,b`, `teams=org/t`, `emails=N`.
 */
const fs = require('fs');

/** GitHub's search order: .github/ first, then root, then docs/. */
const SEARCH_ORDER = ['.github/CODEOWNERS', 'CODEOWNERS', 'docs/CODEOWNERS', '.github/codeowners'];

/**
 * @param {string} text
 * @returns {{pattern: string, owners: string[]}[]}
 */
function parse(text) {
  const rules = [];
  for (const raw of text.split(/\r?\n/)) {
    // `\#` escapes a literal hash at the start of a pattern
    const line = raw.replace(/(^|[^\\])#.*$/, '$1').trim();
    if (!line) continue;
    // `\ ` keeps a space inside the pattern
    const m = line.match(/^((?:\\.|\S)+)\s*(.*)$/);
    const pattern = m[1].replace(/\\(.)/g, '$1');
    const owners = m[2] ? m[2].split(/\s+/) : [];
    rules.push({ pattern, owners });
  }
  return rules;
}

/**
 * Convert a CODEOWNERS pattern to a RegExp over repo-relative paths.
 * @param {string} pattern
 * @returns {RegExp}
 */
function toRegExp(pattern) {
  let p = pattern;
  const dirOnly = p.endsWith('/');
  if (dirOnly) p = p.replace(/\/+$/, '');
  // A slash at the start or in the middle anchors to the repo root
  const anchored = p.startsWith('/') || p.includes('/');
  p = p.replace(/^\/+/, '');
  let re = '';
  for (let i = 0; i < p.length; i++) {
    const c = p[i];
    if (c === '*') {
      if (p[i + 1] === '*') {
        i++;
        if (p[i + 1] === '/') {
          i++;
          re += '(?:.*/)?';
        } else {
          re += '.*';
        }
      } else {
        re += '[^/]*';
      }
    } else if (c === '?') {
      re += '[^/]';
    } else {
      re += c.replace(/[.+^${}()|[\]\\]/g, '\\$&');
    }
  }
  const prefix = anchored ? '^' : '^(?:.*/)?';
  // A match on a directory also covers everything under it, except a
  // trailing single `*` (GitHub: `/docs/*` skips files in docs/ subfolders)
  const trailingStar = /(^|[^*])\*$/.test(p);
  const suffix = dirOnly ? '/.*' : trailingStar ? '' : '(?:/.*)?';
  return new RegExp(`${prefix}${re}${suffix}$`);
}

/**
 * Owners of one path: the last matching rule wins.
 * @param {{pattern: string, owners: string[]}[]} rules
 * @param {string} path
 * @returns {string[] | null} null when no rule matches
 */
function ownersFor(rules, path) {
  const clean = path.replace(/^\.?\//, '');
  for (let i = rules.length - 1; i >= 0; i--) {
    if (toRegExp(rules[i].pattern).test(clean)) return rules[i].owners;
  }
  return null;
}

/**
 * Split owners into users, teams and emails, de-duplicated case-insensitively.
 * @param {string[]} owners
 */
function classify(owners) {
  const users = [];
  const teams = [];
  let emails = 0;
  const seen = new Set();
  for (const o of owners) {
    const key = o.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    if (o.startsWith('@') && o.includes('/')) teams.push(o.slice(1));
    else if (/^@[A-Za-z0-9][A-Za-z0-9-]*$/.test(o)) users.push(o.slice(1));
    else if (o.includes('@')) emails++;
  }
  return { users, teams, emails };
}

/**
 * @param {string} text CODEOWNERS contents
 * @param {'all'|'paths'} mode
 * @param {string[]} [paths]
 */
function select(text, mode, paths = []) {
  const rules = parse(text);
  if (mode === 'all') return classify(rules.flatMap((r) => r.owners));
  return classify(paths.flatMap((p) => ownersFor(rules, p) || []));
}

module.exports = { SEARCH_ORDER, parse, toRegExp, ownersFor, classify, select };

if (require.main === module) {
  const [file, mode] = process.argv.slice(2);
  if (file === 'search-order') {
    process.stdout.write(`${SEARCH_ORDER.join('\n')}\n`);
    process.exit(0);
  }
  const text = fs.readFileSync(file, 'utf8');
  const paths = mode === 'paths'
    ? fs.readFileSync(0, 'utf8').split('\n').map((s) => s.trim()).filter(Boolean)
    : [];
  const r = select(text, mode === 'paths' ? 'paths' : 'all', paths);
  process.stdout.write(`users=${r.users.join(',')}\nteams=${r.teams.join(',')}\nemails=${r.emails}\n`);
}
