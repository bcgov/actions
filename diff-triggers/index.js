const { execFileSync } = require('child_process');
const fs = require('fs');

const { InputError, checkRenamed, getInput, getToken, isDebug, parseBool, parseList, stripQuotes } = require('../shared/inputs.js');

/**
 * Parse trigger paths with the shared list parser (multiline preferred,
 * comma separated or a JSON array). Unsupported formats print the shared
 * before/after error and exit 1.
 * @param {string} raw
 * @returns {string[]}
 */
function parseTriggers(raw) {
  try {
    const list = parseList(raw, 'triggers');
    if (list.length > 0) return list;
    console.error(`::error::Could not parse any triggers from input: ${raw}`);
  } catch (e) {
    if (!(e instanceof InputError)) throw e;
    console.error(e.message);
  }
  process.exit(1);
}

const RESERVED_OUTPUT_KEYS = new Set(['triggered', 'changes']);

/**
 * Parse filters mapping from a YAML-like multiline string.
 * Maps keys to arrays of path patterns.
 *
 * @param {string} raw
 * @returns {Object.<string, string[]>}
 */
function parseFilters(raw) {
  const lines = raw.split(/\r?\n/);
  const filters = {};
  let currentKey = null;

  for (let line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;

    // Detect key line: "key:" or "key: value"
    if (line.match(/^\s*[\w-]+:/)) {
      const colonIndex = trimmed.indexOf(':');
      const key = trimmed.slice(0, colonIndex).trim();
      const val = trimmed.slice(colonIndex + 1).trim();

      if (RESERVED_OUTPUT_KEYS.has(key)) {
        throw new Error(`Filter name '${key}' is reserved by diff-triggers outputs ('triggered', 'changes'). Please choose a different key.`);
      }

      currentKey = key;
      filters[currentKey] = [];

      if (val) {
        if (val.startsWith('[') && val.endsWith(']')) {
          try {
            filters[currentKey] = JSON.parse(val).map(s => stripQuotes(String(s).trim())).filter(Boolean);
          } catch (e) {
            // Non-JSON list like [a, b] — strip brackets before splitting
            const inner = val.slice(1, -1);
            filters[currentKey] = inner.split(',').map(s => stripQuotes(s.trim())).filter(Boolean);
          }
        } else {
          filters[currentKey].push(stripQuotes(val));
        }
      }
    } else if (currentKey && (trimmed.startsWith('-') || line.match(/^\s{2,}/))) {
      // Indented item under key
      const val = trimmed.startsWith('-') ? trimmed.slice(1).trim() : trimmed;
      if (val) {
        filters[currentKey].push(stripQuotes(val));
      }
    }
  }
  return filters;
}

/**
 * Run a git command synchronously. Returns trimmed stdout.
 * @param {string[]} args
 * @param {object} [opts]
 * @returns {string}
 */
function run(args, opts = {}) {
  return execFileSync('git', args, { encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'], ...opts }).trim();
}

async function main() {
  // ── Phase 1: Read inputs & environment ──────────────────────────────
  const triggersStr = process.env.INPUT_TRIGGERS || '';
  const filtersStr = process.env.INPUT_FILTERS || '';
  const inputRef = getInput('diff_base');
  let annotationsEnabled;
  let debug;
  try {
    checkRenamed({ ref: { to: 'diff_base', anchor: 'diff_base' } });
    annotationsEnabled = parseBool(getInput('annotations'), 'annotations', true);
    debug = isDebug();
  } catch (e) {
    console.error(e.message);
    process.exit(1);
  }
  const token = getToken();
  const workflow = process.env.GITHUB_WORKFLOW || '';
  const job = process.env.GITHUB_JOB || '';
  const repo = process.env.GITHUB_REPOSITORY || '';
  const outputPath = process.env.GITHUB_OUTPUT;
  const callerContext = `[${workflow} / ${job}]`;

  // Load event payload for PR metadata
  let payload = {};
  const eventPath = process.env.GITHUB_EVENT_PATH;
  if (eventPath && fs.existsSync(eventPath)) {
    try {
      payload = JSON.parse(fs.readFileSync(eventPath, 'utf8'));
    } catch (e) {
      console.error(`::error::Failed to parse event payload: ${e.message}`);
      process.exit(1);
    }
  }

  // ── Phase 2 & 3: Parse triggers/filters (or short-circuit if omitted) ──────
  const isMultiFilter = !!filtersStr.trim();
  let triggers = [];
  let filters = {};

  if (isMultiFilter) {
    filters = parseFilters(filtersStr);
  } else {
    if (!triggersStr.trim()) {
      console.log(`::group::Diff Triggers — ✅ TRIGGERED | ${repo} ${callerContext}`);
      console.log('  Triggers: (omitted, always fires)');
      console.log('::endgroup::');
      if (annotationsEnabled) {
        console.log(`::notice title=Diff Triggers [${job}]::✅ Omitted (always fires).`);
      }
      if (outputPath) fs.appendFileSync(outputPath, 'triggered=true\n');
      return;
    }
    triggers = parseTriggers(triggersStr);
    if (debug) console.log(`::debug::Parsed triggers: ${JSON.stringify(triggers)}`);
  }

  // Escape for GitHub Actions workflow command encoding
  let escapedTriggers = '';
  if (!isMultiFilter) {
    escapedTriggers = triggersStr
      .replace(/%/g, '%25')
      .replace(/\n/g, '%0A')
      .replace(/\r/g, '%0D');
  }

  // ── Phase 4: Determine comparison ref ──────────────────────────────
  let baseRef = inputRef;
  if (!baseRef) {
    baseRef = payload.pull_request?.base?.repo?.default_branch || '';
  }
  if (!baseRef) {
    baseRef = 'HEAD^';
  }
  const refSource = inputRef ? 'input' : 'default';

  // ── Phase 5: Git operations ────────────────────────────────────────

  // 5a. Ensure repository exists in workspace if caller did not run actions/checkout
  const hasGit = fs.existsSync('.git/HEAD') || fs.existsSync('.git');
  if (!hasGit) {
    const headRemoteUrl = payload.pull_request?.head?.repo?.clone_url
      || payload.repository?.clone_url
      || (repo ? `https://github.com/${repo}.git` : '');

    if (!headRemoteUrl) {
      console.error('::error::No git repository found in workspace and could not determine remote clone URL.');
      process.exit(1);
    }

    let authedHeadUrl = headRemoteUrl;
    if (token && authedHeadUrl.startsWith('https://github.com/')) {
      authedHeadUrl = authedHeadUrl.replace(
        'https://github.com/',
        `https://x-access-token:${token}@github.com/`
      );
    }

    const headRef = payload.pull_request?.head?.sha
      || process.env.GITHUB_SHA
      || process.env.GITHUB_REF
      || 'HEAD';

    run(['init']);
    run(['remote', 'add', 'origin', authedHeadUrl]);
    const isShallow = Boolean(payload.pull_request && !inputRef);
    if (isShallow) {
      run(['fetch', '--depth=1', 'origin', headRef]);
    } else {
      run(['fetch', 'origin', headRef]);
    }
    run(['checkout', '--force', 'FETCH_HEAD']);
  }

  // 5b. Set up base remote
  const baseRemoteUrl = payload.pull_request?.base?.repo?.clone_url
    || payload.repository?.clone_url
    || (repo ? `https://github.com/${repo}.git` : '');

  if (baseRemoteUrl) {
    let authedUrl = baseRemoteUrl;
    if (token && authedUrl.startsWith('https://github.com/')) {
      authedUrl = authedUrl.replace(
        'https://github.com/',
        `https://x-access-token:${token}@github.com/`
      );
    }

    try {
      run(['remote', 'set-url', 'base', authedUrl]);
    } catch {
      run(['remote', 'add', 'base', authedUrl]);
    }
  }

  // 5c. Resolve comparison ref
  let compareRef;
  if (baseRef.startsWith('HEAD')) {
    // Local ref — use directly, but ensure shallow clone has enough depth
    compareRef = baseRef;
    try {
      run(['rev-parse', '--verify', compareRef]);
    } catch {
      // Shallow clone doesn't have the ref — deepen
      try {
        run(['fetch', 'origin', '--deepen=10']);
      } catch {
        try {
          run(['fetch', '--deepen=10']);
        } catch {
          // ignore
        }
      }
      try {
        run(['rev-parse', '--verify', compareRef]);
      } catch {
        console.error(`::error::Cannot resolve ref '${compareRef}'. Ensure sufficient fetch-depth in your checkout step.`);
        process.exit(1);
      }
    }
  } else {
    // Remote ref — fetch from base remote
    run(['fetch', 'base', baseRef]);
    try {
      run(['rev-parse', '--verify', `refs/remotes/base/${baseRef}`]);
      compareRef = `base/${baseRef}`;
    } catch {
      compareRef = baseRef;
    }
  }

  // 5d. Run git diff per trigger/filter
  let triggered = false;
  const matchedTriggers = [];
  let detailsLog = '';
  const filterResults = {};

  if (isMultiFilter) {
    for (const [key, paths] of Object.entries(filters)) {
      let keyTriggered = false;
      detailsLog += `  Filter '${key}':\n`;

      const pathspecs = paths.map(p => {
        if (p.startsWith('!')) {
          return `:(exclude)${p.slice(1)}`;
        }
        return p;
      });

      const diffOutput = run(['diff', compareRef, 'HEAD', '--name-only', '--', ...pathspecs]);

      if (diffOutput) {
        triggered = true;
        keyTriggered = true;
        detailsLog += `    ✔ Triggered by changes in:\n`;
        for (const f of diffOutput.split('\n').filter(Boolean)) {
          matchedTriggers.push(`${key}:${f}`);
          detailsLog += `        ${f}\n`;
        }
      } else {
        detailsLog += `    ✘ No matching changes (patterns: ${paths.join(', ')})\n`;
      }
      filterResults[key] = keyTriggered;
    }
  } else {
    const pathspecs = triggers.map(p => {
      if (p.startsWith('!')) {
        return `:(exclude)${p.slice(1)}`;
      }
      return p;
    });

    const diffOutput = run(['diff', compareRef, 'HEAD', '--name-only', '--', ...pathspecs]);

    if (diffOutput) {
      triggered = true;
      detailsLog += `  ✔ Triggered by changes in:\n`;
      for (const f of diffOutput.split('\n').filter(Boolean)) {
        matchedTriggers.push(f);
        detailsLog += `      ${f}\n`;
      }
    } else {
      detailsLog += `  ✘ No matching changes (patterns: ${triggers.join(', ')})\n`;
    }
  }

  // ── Phase 6: Output and logging ────────────────────────────────────
  if (triggered) {
    const matchedList = matchedTriggers.join(', ');
    console.log(`::group::Diff Triggers — ✅ TRIGGERED | ${repo} ${callerContext}`);
    console.log(`  Filters/Triggers: ${isMultiFilter ? 'filters' : 'triggers'}`);
    console.log(`  Comparing to:     ${compareRef}`);
    console.log(`  Ref source:       ${refSource}`);
    console.log(`  Matched:          ${matchedList}`);
    console.log('');
    console.log(detailsLog);
    console.log('::endgroup::');
    if (annotationsEnabled) {
      if (isMultiFilter) {
        const firedKeys = Object.entries(filterResults).filter(([_, v]) => v).map(([k]) => k).join(', ');
        console.log(`::notice title=Diff Triggers [${job}]::✅ Fired for filters: ${firedKeys}`);
      } else {
        console.log(`::notice title=Diff Triggers [${job}]::✅ Fired. Triggers: ${escapedTriggers}`);
      }
    }
  } else {
    console.log(`::group::Diff Triggers — ⊘ NOT TRIGGERED | ${repo} ${callerContext}`);
    console.log(`  Filters/Triggers: ${isMultiFilter ? 'filters' : 'triggers'}`);
    console.log(`  Comparing to:     ${compareRef}`);
    console.log(`  Ref source:       ${refSource}`);
    console.log('');
    console.log(detailsLog);
    console.log('::endgroup::');
    if (annotationsEnabled) {
      console.log(`::notice title=Diff Triggers [${job}]::⊘ Not fired.`);
    }
  }

  if (outputPath) {
    fs.appendFileSync(outputPath, `triggered=${triggered}\n`);
    if (isMultiFilter) {
      const changedKeys = [];
      for (const [key, val] of Object.entries(filterResults)) {
        fs.appendFileSync(outputPath, `${key}=${val}\n`);
        if (val) changedKeys.push(key);
      }
      fs.appendFileSync(outputPath, `changes=${JSON.stringify(changedKeys)}\n`);
    }
  }
}

if (require.main === module) {
  main().catch(err => {
    console.error(`::error::${err.message || err}`);
    process.exit(1);
  });
}

module.exports = { parseFilters, parseTriggers, stripQuotes };
