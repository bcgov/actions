const { execFileSync } = require('child_process');
const fs = require('fs');

/**
 * Strip one layer of matching single or double quotes.
 * YAML-like filter lists often use dorny-style `- 'path/**'`; those quotes
 * must not reach git pathspecs or matching silently fails.
 * @param {string} s
 * @returns {string}
 */
function stripQuotes(s) {
  if (
    (s.startsWith("'") && s.endsWith("'") && s.length >= 2) ||
    (s.startsWith('"') && s.endsWith('"') && s.length >= 2)
  ) {
    return s.slice(1, -1);
  }
  return s;
}

/**
 * Parse trigger paths from various input formats.
 *
 * Supported formats:
 *   - JSON array:              ["frontend/", "backend/"]
 *   - Parenthesized (bash):    ('frontend/' 'backend/')
 *   - Comma-separated:         frontend/,backend/
 *   - Semicolon-separated:     frontend/;backend/
 *   - Space-separated:         frontend/ backend/
 *   - Quoted (single/double):  "frontend/" "backend/"
 *
 * @param {string} raw - Raw trigger input string
 * @returns {string[]} Parsed trigger paths
 */
function parseTriggers(raw) {
  const trimmed = raw.trim();

  // 1. JSON array: ["frontend/", "backend/"]
  if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
    try {
      const parsed = JSON.parse(trimmed);
      if (Array.isArray(parsed)) {
        const arr = parsed.map(t => String(t).trim()).filter(Boolean);
        if (arr.length > 0) return arr;
        console.error(`::error::Could not parse any triggers from input: ${raw}`);
        process.exit(1);
      }
    } catch {
      // Not valid JSON — fall through to other methods
    }
  }


  // 2. Multiline string (true GitHub Actions standard)
  // If there are newlines, split line-by-line and allow spaces per line
  if (trimmed.includes('\n')) {
    return trimmed
      .split(/\r?\n/)
      .map(line => stripQuotes(line.trim()))
      .filter(Boolean);
  }

  // 3. Strip outer parentheses (bash-style)
  let cleaned = trimmed;
  let isLegacyFormat = false;
  if (cleaned.startsWith('(') && cleaned.endsWith(')')) {
    cleaned = cleaned.slice(1, -1).trim();
    isLegacyFormat = true;
  }

  // 4. Extract quoted strings (single or double quotes)
  const quoted = [];
  const quoteRegex = /(['"])(.*?)\1/g;
  let match;
  while ((match = quoteRegex.exec(cleaned)) !== null) {
    const val = match[2].trim();
    if (val) quoted.push(val);
  }
  if (quoted.length > 0) {
    if (isLegacyFormat) {
      console.log('::warning::Legacy bash-style parenthesized trigger list formatting is deprecated. Please migrate to newline-separated multiline strings.');
    }
    return quoted;
  }

  // 5. Split on whitespace, commas, or semicolons
  const tokens = cleaned.split(/[\s,;]+/).filter(Boolean);
  if (tokens.length === 0) {
    console.error(`::error::Could not parse any triggers from input: ${raw}`);
    process.exit(1);
  }
  console.log('::warning::Delimiter-separated single line trigger formats are deprecated. Please migrate to newline-separated multiline strings.');
  return tokens;
}

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

      currentKey = key;
      filters[currentKey] = [];

      if (val) {
        if (val.startsWith('[') && val.endsWith(']')) {
          try {
            filters[currentKey] = JSON.parse(val).map(s => stripQuotes(String(s).trim())).filter(Boolean);
          } catch (e) {
            filters[currentKey] = val.split(',').map(s => stripQuotes(s.trim())).filter(Boolean);
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
  const inputRef = process.env.INPUT_REF || '';
  const annotationsEnabled = (process.env.INPUT_ANNOTATIONS || 'true').toLowerCase() === 'true';
  const token = process.env.INPUT_GITHUB_TOKEN || '';
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

  // 5a. Set up base remote
  const baseRemoteUrl = payload.pull_request?.base?.repo?.clone_url
    || payload.repository?.clone_url
    || '';

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

  // 5b. Resolve comparison ref
  let compareRef;
  if (baseRef.startsWith('HEAD')) {
    // Local ref — use directly, but ensure shallow clone has enough depth
    compareRef = baseRef;
    try {
      run(['rev-parse', '--verify', compareRef]);
    } catch {
      // Shallow clone doesn't have the ref — deepen
      try {
        run(['fetch', '--deepen=10']);
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

  // 5c. Run git diff per trigger/filter
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
