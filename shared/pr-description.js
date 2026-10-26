'use strict';
// Appends markdown to a PR description once. Used by pr-description-add and
// pr-validate (markdown input). Works on any event: pass `pr`, or it is
// resolved from the event payload.
const fs = require('fs');
const { getInput, getToken } = require('./inputs.js');

function normalizeText(text) {
  return text
    .replace(/\r\n?/g, '\n')
    .split('\n')
    .map((line) => line.trimEnd())
    .join('\n')
    .trim();
}

// [x]/[X]/[ ] count as the same block
function normalizeCheckboxState(text) {
  return text.replace(/^(\s*-?\s*)\[(?: |x|X)\]/gm, '$1[ ]');
}

function alreadyPresent(body, markdown) {
  return normalizeCheckboxState(normalizeText(body)).includes(normalizeCheckboxState(normalizeText(markdown)));
}

function appendBody(body, markdown) {
  return body ? `${body.trim()}\n\n${markdown}` : markdown;
}

/**
 * PR number from the `pr` input, else the event payload.
 * @returns {{ number: number|null, fork: boolean, error?: string }}
 */
function resolvePr(input, event) {
  const raw = String(input ?? '').trim().replace(/^#/, '');
  if (raw) {
    if (!/^[1-9]\d*$/.test(raw)) return { number: null, fork: false, error: `pr input must be a PR number, got: ${input}` };
    return { number: Number(raw), fork: false };
  }
  const e = event || {};
  if (e.pull_request && e.pull_request.number) {
    const head = e.pull_request.head;
    return { number: e.pull_request.number, fork: Boolean(head && head.repo && head.repo.fork) };
  }
  if (e.issue && e.issue.pull_request && e.issue.number) return { number: e.issue.number, fork: false };
  const runPrs = e.workflow_run && e.workflow_run.pull_requests;
  if (Array.isArray(runPrs) && runPrs.length && runPrs[0].number) return { number: runPrs[0].number, fork: false };
  if (e.number && (e.pull_request || e.action)) return { number: e.number, fork: false };
  return {
    number: null,
    fork: false,
    error: 'No pull request in this event. Set the pr input (e.g. pr: ${{ steps.track.outputs.pr }}).',
  };
}

function readEvent(env = process.env) {
  try {
    return env.GITHUB_EVENT_PATH ? JSON.parse(fs.readFileSync(env.GITHUB_EVENT_PATH, 'utf8')) : {};
  } catch {
    return {};
  }
}

/** Returns an exit code; 0 on success or no-op. */
async function run(env = process.env, fetchImpl = fetch) {
  const markdown = getInput('markdown', env);
  if (!markdown) return 0;
  const pr = resolvePr(getInput('pr', env), readEvent(env));
  if (pr.error) {
    console.log(`::error::${pr.error}`);
    return 1;
  }
  if (pr.fork) {
    console.log('::notice::Cannot update PR descriptions from fork workflows (read-only token on the base repo). See https://github.com/bcgov/actions/blob/main/README.md#fork-pull-requests');
    return 0;
  }
  const api = env.GITHUB_API_URL || 'https://api.github.com';
  const url = `${api}/repos/${env.GITHUB_REPOSITORY}/pulls/${pr.number}`;
  const headers = {
    Authorization: `Bearer ${getToken(env)}`,
    Accept: 'application/vnd.github+json',
    'Content-Type': 'application/json',
  };
  const res = await fetchImpl(url, { headers });
  if (!res.ok) {
    console.log(`::error::Failed to fetch PR #${pr.number} (HTTP ${res.status}). Not updating, to avoid overwriting the description.`);
    return 1;
  }
  const body = (await res.json()).body || '';
  if (alreadyPresent(body, markdown)) {
    console.log('Markdown is already present (ignoring checkbox state).');
    return 0;
  }
  const upd = await fetchImpl(url, { method: 'PATCH', headers, body: JSON.stringify({ body: appendBody(body, markdown) }) });
  if (!upd.ok) {
    console.log(`::error::Failed to update PR #${pr.number} (HTTP ${upd.status}). Check pull-requests: write.`);
    return 1;
  }
  console.log(`PR #${pr.number} description updated.`);
  return 0;
}

module.exports = { normalizeText, normalizeCheckboxState, alreadyPresent, appendBody, resolvePr, run };
if (require.main === module) run().then((code) => process.exit(code));
