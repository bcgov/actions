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
    ...items.map(i => `    ${i}`),
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
 * Debug is on when the `debug` input is true or the run has step debug
 * logging enabled (re-run with debug logging sets RUNNER_DEBUG=1).
 * @param {NodeJS.ProcessEnv} [env]
 * @returns {boolean}
 */
function isDebug(env = process.env) {
  return parseBool(getInput('debug', env), 'debug') || env.RUNNER_DEBUG === '1';
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

module.exports = {
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
 */
if (require.main === module) {
  const [cmd, name, a, b] = process.argv.slice(2);
  try {
    let out;
    if (cmd === 'list') out = parseList(getInput(name), name).join('\n');
    else if (cmd === 'bool') out = String(parseBool(getInput(name), name, a === 'true'));
    else if (cmd === 'enum') out = parseEnum(getInput(name), name, a.split(','), b);
    else if (cmd === 'debug') out = String(isDebug());
    else throw new Error(`unknown command: ${cmd}`);
    if (out) process.stdout.write(`${out}\n`);
  } catch (e) {
    console.error(e instanceof InputError ? e.message : `::error::${e.message}`);
    process.exit(1);
  }
}
