// Appends `markdown` to the PR description once. Formerly pr-description-add.
const fs = require('fs');
const { getInput, getToken } = require('../shared/inputs.js');

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

async function main() {
  const markdown = getInput('markdown');
  if (!markdown) return;
  const event = JSON.parse(fs.readFileSync(process.env.GITHUB_EVENT_PATH, 'utf8'));
  const pr = event.pull_request;
  if (!pr) {
    console.log('::error::markdown needs a pull_request event.');
    process.exit(1);
  }
  if (pr.head && pr.head.repo && pr.head.repo.fork) {
    console.log('::notice::Cannot update PR descriptions from fork workflows (read-only token on the base repo). See https://github.com/bcgov/actions/blob/main/README.md#fork-pull-requests');
    return;
  }
  const api = process.env.GITHUB_API_URL || 'https://api.github.com';
  const url = `${api}/repos/${process.env.GITHUB_REPOSITORY}/pulls/${pr.number}`;
  const headers = {
    Authorization: `Bearer ${getToken()}`,
    Accept: 'application/vnd.github+json',
    'Content-Type': 'application/json',
  };
  const res = await fetch(url, { headers });
  if (!res.ok) {
    console.log(`::error::Failed to fetch PR #${pr.number} (HTTP ${res.status}). Not updating, to avoid overwriting the description.`);
    process.exit(1);
  }
  const body = (await res.json()).body || '';
  if (alreadyPresent(body, markdown)) {
    console.log('Markdown is already present (ignoring checkbox state).');
    return;
  }
  const upd = await fetch(url, { method: 'PATCH', headers, body: JSON.stringify({ body: appendBody(body, markdown) }) });
  if (!upd.ok) {
    console.log(`::error::Failed to update PR #${pr.number} (HTTP ${upd.status}). Check pull-requests: write.`);
    process.exit(1);
  }
  console.log('PR description updated.');
}

module.exports = { normalizeText, normalizeCheckboxState, alreadyPresent, appendBody };
if (require.main === module) main();
