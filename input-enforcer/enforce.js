'use strict';
/**
 * Input enforcer: fail when a caller passes an input the action does not
 * declare. GitHub only warns ("Unexpected input(s)") and keeps going, so a
 * mistyped or stale `with:` key is otherwise silently ignored.
 *
 * Declare-vs-given only: the declared names come from the action's own
 * action.yml, nothing else is configured per action.
 *
 * Used by the input-enforcer action (index.js) and required directly by Node
 * actions in bcgov/actions, so there is one checker.
 */
const fs = require('node:fs');
const path = require('node:path');

class InputError extends Error {}

/**
 * Declared input names from an action.yml (top-level `inputs:` block).
 * A small line parser so the enforcer needs no YAML dependency.
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
    const m =
      line.match(/^(\s+)(['"]?)([^'":#\s][^'":#]*?)\2:\s*(#.*)?$/) ||
      line.match(/^(\s+)(['"]?)([^'":#\s][^'":#]*?)\2:\s/);
    if (!m) continue;
    if (indent < 0) indent = m[1].length;
    if (m[1].length === indent) names.push(m[3].trim());
  }
  return names;
}

/** Runner env form of an input name: INPUT_<NAME>, spaces as `_`. */
const envKey = name => name.replace(/ /g, '_').toUpperCase();

/**
 * owner/repo of an action checked out by the runner
 * (.../_actions/<owner>/<repo>/<ref>/<dir>), else the workflow repository.
 * @param {string} actionDir
 * @param {NodeJS.ProcessEnv} [env]
 * @returns {string}
 */
function actionRepo(actionDir, env = process.env) {
  const m = path.resolve(actionDir).split(path.sep).join('/').match(/\/_actions\/([^/]+)\/([^/]+)\//);
  return m ? `${m[1]}/${m[2]}` : env.GITHUB_REPOSITORY || 'bcgov/actions';
}

/**
 * Error text: names each bad key, lists the declared inputs, links the
 * action README. Newlines are %0A so the annotation keeps its layout.
 * @param {string} action - action directory name, e.g. builder
 * @param {string[]} unknown - bad keys as the caller wrote them
 * @param {string[]} declared
 * @param {{repo?: string}} [opts]
 * @returns {string}
 */
function unknownInputsMessage(action, unknown, declared, opts = {}) {
  const repo = opts.repo || 'bcgov/actions';
  return [
    `::error title=${action}: unknown input::Unknown input(s) for ${action}: ${unknown.join(', ')}`,
    ...unknown.map(key => `  ${key}: not an input of ${action}`),
    `Inputs: ${declared.join(', ')}`,
    `Docs: https://github.com/${repo}/blob/main/${action}/README.md`,
  ].join('%0A');
}

/**
 * Throw InputError when `given` holds names `declared` does not.
 * `raw: true` (composite `toJSON(inputs)` keys) folds case only: the key is
 * the name as written, and `${{ inputs.build_args }}` never sees `build args`.
 * Otherwise (Node INPUT_* env names) spaces map to `_` as the runner does.
 * @param {string} action
 * @param {string[]} given
 * @param {string[]} declared
 * @param {{raw?: boolean, repo?: string}} [opts]
 */
function assertKnownInputs(action, given, declared, opts = {}) {
  const norm = opts.raw ? k => k.toLowerCase() : envKey;
  const known = new Set(declared.map(norm));
  const unknown = [...new Set(given)].filter(g => !known.has(norm(g)));
  if (unknown.length) throw new InputError(unknownInputsMessage(action, unknown, declared, opts));
}

/**
 * Check given input names against the action.yml in actionDir.
 * @param {string} actionDir - directory holding action.yml
 * @param {string[]} given
 * @param {{raw?: boolean, repo?: string}} [opts]
 */
function enforce(actionDir, given, opts = {}) {
  const file = ['action.yml', 'action.yaml'].map(f => path.join(actionDir, f)).find(f => fs.existsSync(f));
  if (!file) throw new Error(`no action.yml in ${actionDir}`);
  const action = path.basename(path.resolve(actionDir));
  const repo = opts.repo || actionRepo(actionDir);
  assertKnownInputs(action, given, declaredInputs(fs.readFileSync(file, 'utf8')), { ...opts, repo });
}

/**
 * Keys of a composite's `${{ toJSON(inputs) }}` (holds undeclared keys too).
 * @param {string} json
 * @returns {string[]}
 */
function jsonKeys(json) {
  let obj;
  try {
    obj = JSON.parse(json || '{}');
  } catch (e) {
    throw new Error(`inputs is not JSON (pass \${{ toJSON(inputs) }}): ${e.message}`);
  }
  if (!obj || typeof obj !== 'object' || Array.isArray(obj)) throw new Error('inputs must be a JSON object');
  return Object.keys(obj);
}

/**
 * Node actions: check the runner's INPUT_* env (set for every `with:` key,
 * declared or not) against the action's own action.yml. Call first:
 *   require('../input-enforcer/enforce.js').enforceNode(__dirname)
 * Prints the annotation and exits 1 on unknown inputs.
 * @param {string} actionDir
 * @param {NodeJS.ProcessEnv} [env]
 */
function enforceNode(actionDir, env = process.env) {
  const given = Object.keys(env)
    .filter(k => k.startsWith('INPUT_'))
    .map(k => k.slice(6).toLowerCase());
  run(() => enforce(actionDir, given));
}

function run(fn) {
  try {
    fn();
  } catch (e) {
    console.log(e instanceof InputError ? e.message : `::error::${e.message}`);
    process.exit(1);
  }
}

module.exports = {
  InputError,
  actionRepo,
  assertKnownInputs,
  declaredInputs,
  enforce,
  enforceNode,
  jsonKeys,
  run,
  unknownInputsMessage,
};

/*
 * CLI: node enforce.js <action_dir> '<toJSON(inputs)>'
 * (JSON may also come from INPUTS_JSON). Used by tests and CI.
 */
if (require.main === module) {
  const [dir, json] = process.argv.slice(2);
  run(() => enforce(dir, jsonKeys(json ?? process.env.INPUTS_JSON), { raw: true }));
}
