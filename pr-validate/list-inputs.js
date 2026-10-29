#!/usr/bin/env node
// Fail list inputs passed to bcgov/actions* in a format parseList rejects.
// actionlint cannot check input formats, and some of these fail silently at
// runtime (triggers in a format diff-triggers cannot read skip pr-close and
// path filters). Line-based: reads each `with:` block whose sibling `uses:`
// (before or after it) points at bcgov/actions or bcgov/actions-openshift.
// Usage: node list-inputs.js <workflow-file>...
'use strict';
const fs = require('fs');
const path = require('path');
const { InputError, parseList } = require(path.join(__dirname, '..', 'shared', 'inputs.js'));

// Every shared input read with parseList (diff-triggers, ghcr-cleanup,
// image-tracker, and the builder/test-and-analyse callers) or with
// actions-openshift's shared/inputs.sh input_list (cert-expiry, cleanup-pr,
// sysdig-monitor).
const LIST_INPUTS = new Set([
  'triggers', 'packages', 'package', 'tags', 'keep_digests',
  'components', 'hosts', 'cleanup_name', 'remove_pvc',
]);
const BCGOV = /bcgov\/actions(-openshift)?[/@]/;

const indentOf = l => l.match(/^ */)[0].length;
const blank = l => /^\s*(#.*)?$/.test(l);
// Column where a line's key starts: after "- " for sequence items.
const keyCol = l => { const m = l.match(/^( *)(- +)?/); return m[0].length; };

function unquote(v) {
  if (/^'.*'$/s.test(v)) return v.slice(1, -1).replace(/''/g, "'");
  if (/^".*"$/s.test(v)) return v.slice(1, -1).replace(/\\"/g, '"');
  return v;
}

// Sibling keys of the mapping that holds lines[i] (key at column col).
function siblingUses(lines, i, col) {
  for (let j = i - 1; j >= 0; j--) {
    const l = lines[j];
    if (blank(l)) continue;
    if (keyCol(l) === col && /^ *(- +)?uses:/.test(l)) return l;
    if (/^ *- /.test(l) && keyCol(l) === col) break; // start of this item
    if (indentOf(l) < col) break;
  }
  for (let j = i + 1; j < lines.length; j++) {
    const l = lines[j];
    if (blank(l)) continue;
    if (indentOf(l) < col || (/^ *- /.test(l) && indentOf(l) < col + 1)) break;
    if (indentOf(l) === col && /^ *uses:/.test(l)) return l;
  }
  return null;
}

function checkFile(file) {
  const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);
  const errors = [];
  for (let i = 0; i < lines.length; i++) {
    if (!/^ *(- +)?with: *(#.*)?$/.test(lines[i])) continue;
    const col = keyCol(lines[i]);
    const uses = siblingUses(lines, i, col);
    if (!uses || !BCGOV.test(uses)) continue;
    let child = -1;
    for (let j = i + 1; j < lines.length; j++) {
      const l = lines[j];
      if (blank(l)) continue;
      const ind = indentOf(l);
      if (ind <= col) break;
      if (child < 0) child = ind;
      if (ind !== child) continue;
      const m = l.match(/^ *([A-Za-z0-9_-]+): *(.*)$/);
      if (!m || !LIST_INPUTS.has(m[1])) continue;
      const name = m[1];
      let raw = m[2];
      let value;
      if (/^[|>]/.test(raw)) {
        const body = [];
        for (let k = j + 1; k < lines.length; k++) {
          if (lines[k].trim() && indentOf(lines[k]) <= child) break;
          body.push(lines[k].trim());
        }
        value = body.join(raw.startsWith('>') ? ' ' : '\n');
      } else {
        if (!/^['"]/.test(raw)) raw = raw.replace(/\s+#.*$/, '');
        else raw = raw.replace(/(['"])\s+#.*$/, '$1');
        value = unquote(raw.trim());
      }
      // cert-expiry drops each line's '# comment' before reading hosts.
      if (name === 'hosts') value = value.split('\n').map(v => v.replace(/#.*$/, '').trim()).join('\n');
      // ${{ }} expressions are resolved at runtime; check the other lines only.
      value = value.split('\n').filter(v => !v.includes('${{')).join('\n');
      try {
        parseList(value, name);
      } catch (e) {
        if (!(e instanceof InputError)) throw e;
        errors.push(`::error file=${file},line=${j + 1},title=${name}: list format::` +
          `${name} takes one item per line (${name}: |) or a single value. ` +
          `Comma, space, bracket and JSON lists are not read. Got: ${value.replace(/\n/g, '%0A')}`);
      }
    }
  }
  return errors;
}

const errors = process.argv.slice(2).flatMap(checkFile);
for (const e of errors) console.log(e);
process.exit(errors.length ? 1 : 0);
