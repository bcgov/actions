'use strict';
/**
 * Shared input parsing for bcgov/actions.
 *
 * Every action in this repo reads its inputs through these helpers so lists,
 * booleans, debug and token behave the same everywhere. Node actions
 * `require('../shared/inputs.js')`; composite actions call the CLI at the
 * bottom of this file (`node "$GITHUB_ACTION_PATH/../shared/inputs.js" ...`).
 * GitHub downloads the whole repository for `uses: bcgov/actions/<action>@sha`,
 * so `../shared` is always present next to the action.
 */

/**
 * Read an input the way the runner exposes it: INPUT_<NAME>, spaces as `_`.
 * @param {string} name
 * @param {NodeJS.ProcessEnv} [env]
 * @returns {string}
 */
function getInput(name, env = process.env) {
  return String(env[`INPUT_${name.replace(/ /g, '_').toUpperCase()}`] ?? '').trim();
}

/**
 * Strip one layer of matching single or double quotes.
 * @param {string} s
 * @returns {string}
 */
function stripQuotes(s) {
  if (
    s.length >= 2 &&
    ((s.startsWith("'") && s.endsWith("'")) || (s.startsWith('"') && s.endsWith('"')))
  ) {
    return s.slice(1, -1);
  }
  return s;
}

/**
 * Error text for a list in an unsupported format. Names the bad value and
 * shows the same items one per line. Newlines are encoded as %0A so the
 * annotation keeps its layout.
 * @param {string} name - input name, e.g. triggers
 * @param {string} raw
 * @returns {string}
 */
function listFormatMessage(name, raw) {
  const trimmed = raw.trim();
  const inner = /^[([].*[)\]]$/s.test(trimmed) ? trimmed.slice(1, -1) : trimmed;
  const found = (inner.match(/'[^']*'|"[^"]*"|[^\s,;]+/g) || [])
    .map(t => stripQuotes(t.trim()))
    .filter(Boolean);
  const items = found.length ? found : ['backend/', 'frontend/'];
  return [
    `::error title=${name}: list format::Invalid ${name} input: ${trimmed}`,
    `${name} takes one item per line, or a single value.`,
    'Got:',
    `  ${name}: ${trimmed}`,
    'Use:',
    `  ${name}: |`,
    // Items with spaces keep their quotes, so the suggested block parses
    ...items.map(i => `    ${/\s/.test(i) ? `"${i}"` : i}`),
    `Multiline input syntax: ${WITH_DOCS}`,
  ].join('%0A');
}

/** GitHub's docs on step inputs (`with:`), including multiline values. */
const WITH_DOCS =
  'https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idstepswith';

class InputError extends Error {}

/**
 * True when s has a comma outside {...}, so globs like src/{a,b}/** are one item.
 * @param {string} s
 * @returns {boolean}
 */
function hasListComma(s) {
  let depth = 0;
  for (const ch of s) {
    if (ch === '{') depth++;
    if (ch === '}') depth = Math.max(0, depth - 1);
    if (ch === ',' && depth === 0) return true;
  }
  return false;
}

/**
 * Parse a list input: one item per line, or a single value.
 *
 * Blank lines are ignored and one layer of quotes around each item is
 * removed. An item that holds a list of its own (commas outside {...} globs,
 * semicolons, spaces outside quotes, or [..] / (..) brackets) throws an
 * InputError whose message is listFormatMessage().
 *
 * @param {string} raw
 * @param {string} [name]
 * @returns {string[]}
 */
function parseList(raw, name = 'input') {
  const trimmed = String(raw ?? '').trim();
  if (!trimmed) return [];

  const bad = () => new InputError(listFormatMessage(name, trimmed));
  const quoted = t => /^'[^']*'$|^"[^"]*"$/.test(t);
  if (/^[([].*[)\]]$/s.test(trimmed)) throw bad();

  const items = [];
  for (const line of trimmed.split(/\r?\n/)) {
    const t = line.trim();
    if (!t) continue;
    if (!quoted(t) && (/[\s;'"]/.test(t) || hasListComma(t) || /^[([]|[)\]]$/.test(t))) throw bad();
    const item = stripQuotes(t);
    if (item) items.push(item);
  }
  return items;
}

/**
 * Parse a boolean input. Accepts true/false in any case (the YAML 1.2 core
 * schema values GitHub's `type: boolean` uses); anything else is an error.
 * @param {string} raw
 * @param {string} name
 * @param {boolean} [fallback] - used when the input is empty
 * @returns {boolean}
 */
function parseBool(raw, name, fallback = false) {
  const v = String(raw ?? '').trim().toLowerCase();
  if (v === '') return fallback;
  if (v === 'true') return true;
  if (v === 'false') return false;
  throw new InputError(`::error title=${name}: not a boolean::Invalid ${name} input: ${raw}. Use true or false.`);
}

/**
 * Parse an enum input.
 * @param {string} raw
 * @param {string} name
 * @param {string[]} allowed
 * @param {string} fallback
 * @returns {string}
 */
function parseEnum(raw, name, allowed, fallback) {
  const v = String(raw ?? '').trim().toLowerCase();
  if (v === '') return fallback;
  if (allowed.includes(v)) return v;
  throw new InputError(
    `::error title=${name}: unsupported value::Invalid ${name} input: ${raw}. Use one of: ${allowed.join(', ')}.`
  );
}

/**
 * Debug is on when the run has step debug logging enabled (re-run with
 * debug logging sets RUNNER_DEBUG=1). Actions have no `debug` input.
 * @param {NodeJS.ProcessEnv} [env]
 * @returns {boolean}
 */
function isDebug(env = process.env) {
  return env.RUNNER_DEBUG === '1';
}

/**
 * The `token` input, else GITHUB_TOKEN from the env. Actions default `token`
 * to github.token, so callers only set it to use a PAT.
 * @param {NodeJS.ProcessEnv} [env]
 * @returns {string}
 */
function getToken(env = process.env) {
  return getInput('token', env) || String(env.GITHUB_TOKEN ?? '').trim();
}


/** Inputs reference for renamed and removed inputs. */
const INPUTS_DOCS = 'https://github.com/bcgov/actions/blob/main/docs/INPUTS.md';

/**
 * Inputs renamed or removed in v0.11, per action: old name -> new name, or
 * null when the input was removed with no replacement. Error text only: old
 * names are never accepted. Dropped at v2.
 */
const RENAMED = {
  builder: {
    build_file: 'file',
    build_context: 'context',
    ref: 'base',
    debug: null,
    sbom: null,
    repository: null,
    username: null,
  },
  'diff-triggers': { ref: 'base', debug: null, annotations: null },
  'image-tracker': { package: 'packages', dir: 'working_directory', registry: null, debug: null },
  'pr-description-add': { add_markdown: 'markdown', debug: null },
  'pr-validate': { add_markdown: 'markdown', conventional_commits: null },
  'test-and-analyse': {
    dir: 'working_directory',
    ref: 'base',
    dep_scan: 'unused_deps',
    debug: null,
    node_version_file: null,
    java_version_file: null,
    python_version_file: null,
    repository: null,
    branch: null,
    checkout_path: null,
    require_sonar: null,
  },
  'workflow-notifier': { debug: null, labels: null, assign: null },
  'workflow-results': { summary: null, annotations: null, debug: null },
};

/** Runner env form of an input name: INPUT_<NAME>, spaces as `_`. */
const envKey = name => name.replace(/ /g, '_').toUpperCase();

/**
 * Declared input names from an action.yml (top-level `inputs:` block).
 * A small line parser so actions need no YAML dependency.
 * @param {string} yml
 * @returns {string[]}
 */
function declaredInputs(yml) {
  const names = [];
  let inBlock = false;
  let indent = -1;
  for (const line of String(yml).split(/\r?\n/)) {
    if (/^inputs:\s*(#.*)?$/.test(line)) {
      inBlock = true;
      continue;
    }
    if (!inBlock || /^\s*(#.*)?$/.test(line)) continue;
    if (/^\S/.test(line)) break;
    const m = line.match(/^(\s+)(['"]?)([^'":#\s][^'":#]*?)\2:\s*(#.*)?$/) || line.match(/^(\s+)(['"]?)([^'":#\s][^'":#]*?)\2:\s/);
    if (!m) continue;
    if (indent < 0) indent = m[1].length;
    if (m[1].length === indent) names.push(m[3].trim());
  }
  return names;
}

/**
 * Error text for inputs the action does not declare. Names each bad key, the
 * replacement when known, and links the action README and INPUTS.md.
 * @param {string} action - action directory name, e.g. builder
 * @param {string[]} unknown - bad keys as the caller wrote them
 * @param {string[]} declared
 * @param {{repo?: string, renamed?: Record<string, Record<string, string|null>>}} [opts]
 * @returns {string}
 */
function unknownInputsMessage(action, unknown, declared, opts = {}) {
  const repo = opts.repo || 'bcgov/actions';
  const renamed = (opts.renamed || RENAMED)[action] || {};
  const lines = [`::error title=${action}: unknown input::Unknown input(s) for ${action}: ${unknown.join(', ')}`];
  for (const key of unknown) {
    const hit = Object.keys(renamed).find(k => k.toLowerCase() === key.toLowerCase());
    if (hit && renamed[hit]) lines.push(`  ${key}: renamed to ${renamed[hit]}`);
    else if (hit) lines.push(`  ${key}: removed (no replacement)`);
    else lines.push(`  ${key}: not an input of ${action}`);
  }
  lines.push(`Inputs: ${declared.join(', ')}`);
  lines.push(`Docs: https://github.com/${repo}/blob/main/${action}/README.md`);
  lines.push(`Reference: ${INPUTS_DOCS}`);
  return lines.join('%0A');
}

/**
 * Throw InputError when the caller passed inputs the action does not declare.
 * GitHub only warns ("Unexpected input(s)") and keeps going, so a renamed
 * input is silently ignored without this check.
 * @param {string} action
 * @param {string[]} given - input names the caller passed
 * @param {string[]} declared - names from action.yml
 * @param {object} [opts] - see unknownInputsMessage; `raw: true` compares
 *   composite key names case-insensitively, without space -> `_`
 */
function assertKnownInputs(action, given, declared, opts = {}) {
  // Composite (INPUTS_JSON) keys are raw names: `${{ inputs.build_args }}`
  // never sees `build args`, so only case is folded. Node INPUT_* env names
  // already have spaces as `_`, so envKey normalization applies there only.
  const norm = opts.raw ? k => k.toLowerCase() : envKey;
  const known = new Set(declared.map(norm));
  const unknown = [...new Set(given)].filter(g => !known.has(norm(g)));
  if (unknown.length) throw new InputError(unknownInputsMessage(action, unknown, declared, opts));
}

/**
 * Input names the caller passed. Composite actions set INPUTS_JSON to
 * `${{ toJSON(inputs) }}` (their own steps set INPUT_* vars, so the env is
 * not a reliable source); node actions read INPUT_* from the env, which the
 * runner sets for every `with:` key, declared or not.
 * @param {NodeJS.ProcessEnv} [env]
 * @returns {string[]}
 */
function givenInputs(env = process.env) {
  if (env.INPUTS_JSON) return Object.keys(JSON.parse(env.INPUTS_JSON) || {});
  return Object.keys(env)
    .filter(k => k.startsWith('INPUT_'))
    .map(k => k.slice(6).toLowerCase());
}

/**
 * Check this action's inputs against its action.yml. Node actions call this
 * first: `assertKnownActionInputs(__dirname)`.
 * @param {string} actionDir - directory holding action.yml
 * @param {NodeJS.ProcessEnv} [env]
 */
function assertKnownActionInputs(actionDir, env = process.env) {
  const fs = require('node:fs');
  const path = require('node:path');
  const file = ['action.yml', 'action.yaml'].map(f => path.join(actionDir, f)).find(f => fs.existsSync(f));
  if (!file) throw new Error(`no action.yml in ${actionDir}`);
  const action = path.basename(path.resolve(actionDir));
  assertKnownInputs(action, givenInputs(env), declaredInputs(fs.readFileSync(file, 'utf8')), { raw: Boolean(env.INPUTS_JSON) });
}

module.exports = {
  INPUTS_DOCS,
  RENAMED,
  assertKnownActionInputs,
  assertKnownInputs,
  declaredInputs,
  givenInputs,
  unknownInputsMessage,
  InputError,
  getInput,
  getToken,
  isDebug,
  listFormatMessage,
  parseBool,
  parseEnum,
  parseList,
  stripQuotes,
};

/*
 * CLI for composite actions. Reads the value from INPUT_<NAME> (set it with
 * `env:`), prints the result on stdout, exits 1 with an annotation on error.
 *   list <name>                 one item per line (input: one per line or a single value)
 *   bool <name> [true|false]    true or false (second arg is the default)
 *   enum <name> <a,b,c> <dflt>  the chosen value
 *   debug                       true or false
 *   token                       the token input, else GITHUB_TOKEN
 *   assert-known <action_dir>   fail on inputs action.yml does not declare
 *                               (composite: set INPUTS_JSON: ${{ toJSON(inputs) }})
 */
if (require.main === module) {
  const [cmd, name, a, b] = process.argv.slice(2);
  try {
    let out;
    if (cmd === 'list') out = parseList(getInput(name), name).join('\n');
    else if (cmd === 'bool') out = String(parseBool(getInput(name), name, a === 'true'));
    else if (cmd === 'enum') out = parseEnum(getInput(name), name, a.split(','), b);
    else if (cmd === 'debug') out = String(isDebug());
    else if (cmd === 'token') out = getToken();
    else if (cmd === 'assert-known') assertKnownActionInputs(name);
    else throw new Error(`unknown command: ${cmd}`);
    if (out) process.stdout.write(`${out}\n`);
  } catch (e) {
    console.error(e instanceof InputError ? e.message : `::error::${e.message}`);
    process.exit(1);
  }
}
