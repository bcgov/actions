'use strict';
// Faithful port of bcgov/action-get-pr@v0.3.1 (28b0adf) lookup behaviour.
// Used by image-tracker when packages is omitted. Not a reason to deploy by PR tag.

const fs = require('node:fs');
const path = require('node:path');
const { execSync } = require('node:child_process');

const DEFAULT_IGNORE_TITLES = ['Dependency Dashboard', 'ZAP Security Report'];
const API_VERSION = '2022-11-28';
const USER_AGENT = 'bcgov-actions';
const PR_RE = /^\d+$/;

/**
 * Event PR number for digest-path outputs.pr (no API). pull_request_target
 * shares the pull_request payload shape; get-pr itself only handled pull_request.
 * @param {string} eventName
 * @param {object} [event]
 * @param {NodeJS.ProcessEnv} [env]
 * @returns {string}
 */
function prNumberFromEvent(eventName, event, env = process.env) {
  const name = eventName || '';
  const payload = event || {};

  if (name === 'pull_request' || name === 'pull_request_target') {
    if (payload.pull_request && payload.pull_request.number) {
      return String(payload.pull_request.number);
    }
    if (payload.number) return String(payload.number);
    if (env.GITHUB_EVENT_NUMBER) return String(env.GITHUB_EVENT_NUMBER);
    return '';
  }

  if (name === 'merge_group') {
    const headRef =
      (payload.merge_group && payload.merge_group.head_ref) || env.MERGE_GROUP_HEAD_REF || '';
    const match = String(headRef).match(/\/pr-(\d+)(?:-[0-9a-f]+)?$/);
    return match ? match[1] : '';
  }

  return '';
}

function prFromCommitMessage(msg) {
  if (!msg) return '';
  const firstLine = String(msg).split('\n')[0];
  const squashMatch = firstLine.match(/\(#(\d+)\)$/);
  if (squashMatch) return squashMatch[1];
  const standardMatch = firstLine.match(/Merge pull request #(\d+)/i);
  if (standardMatch) return standardMatch[1];
  const generalMatch = String(msg).match(/PR #(\d+)/i);
  if (generalMatch) return generalMatch[1];
  return '';
}

function loadIgnoreTitles(cwd = process.cwd(), exists = fs.existsSync, readFile = fs.readFileSync) {
  const rulesPath = path.join(cwd, 'rules.yml');
  const titles = [];
  if (exists(rulesPath)) {
    try {
      const content = readFile(rulesPath, 'utf8');
      for (const line of String(content).split('\n')) {
        const match = line.match(/^\s*-\s*["']?([^"'\r\n]+)["']?/);
        if (match) titles.push(match[1].trim());
      }
    } catch {
      // get-pr ignores a unreadable rules.yml and uses the defaults
    }
  }
  return titles.length > 0 ? titles : DEFAULT_IGNORE_TITLES.slice();
}

function commitShaForEvent(eventName, event, env = process.env, sha = '') {
  const payload = event || {};
  let commitSha = sha || env.TEST_SHA || env.GITHUB_SHA || '';
  if (eventName === 'push') {
    commitSha = env.TEST_EVENT_AFTER || payload.after || env.GITHUB_EVENT_AFTER || commitSha;
  }
  return String(commitSha || '').trim();
}

function pullsUrl(repository, sha) {
  return `https://api.github.com/repos/${repository}/commits/${sha}/pulls`;
}

function commitUrl(repository, sha) {
  return `https://api.github.com/repos/${repository}/commits/${sha}`;
}

function apiHeaders(token) {
  return {
    Accept: 'application/vnd.github+json',
    Authorization: `Bearer ${token}`,
    'X-GitHub-Api-Version': API_VERSION,
    'User-Agent': USER_AGENT
  };
}

/**
 * Tier 1 of get-pr: GET /commits/{sha}/pulls, up to 3 attempts (indexing lag),
 * 10s timeout, 2s/4s backoff. Uses body[0]. 401/403 stop and leave pr unset
 * so Tier 2 can run.
 */
async function fetchAssociatedPullNumber({
  repository,
  sha,
  token,
  fetchImpl = fetch,
  sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
}) {
  const url = pullsUrl(repository, sha);
  let attempt = 1;
  const maxAttempts = 3;
  let sleepMs = 2000;

  while (attempt <= maxAttempts) {
    let timeoutId;
    try {
      const controller = new AbortController();
      timeoutId = setTimeout(() => controller.abort(), 10000);
      const res = await fetchImpl(url, { headers: apiHeaders(token), signal: controller.signal });
      if (res.status === 200) {
        const body = await res.json();
        if (body && body[0] && body[0].number) return String(body[0].number);
      } else if (res.status === 401 || res.status === 403) {
        return '';
      } else {
        return '';
      }
    } catch {
      // retry like get-pr
    } finally {
      if (timeoutId) clearTimeout(timeoutId);
    }

    if (attempt < maxAttempts) {
      await sleep(sleepMs);
      sleepMs *= 2;
    }
    attempt += 1;
  }
  return '';
}

async function fetchPrFromCommitMessage({
  repository,
  sha,
  token,
  fetchImpl = fetch
}) {
  try {
    const res = await fetchImpl(commitUrl(repository, sha), { headers: apiHeaders(token) });
    if (res.status !== 200) return '';
    const commitData = await res.json();
    const msg = commitData.commit && commitData.commit.message;
    return prFromCommitMessage(msg);
  } catch {
    return '';
  }
}

function prFromLocalGitLog(eventName, cwd = process.cwd(), exec = execSync, exists = fs.existsSync) {
  if (!exists(path.join(cwd, '.git'))) return '';
  try {
    const commitsToSearch = eventName === 'workflow_dispatch' ? 10 : 1;
    const log = exec(`git log --pretty=format:%s -${commitsToSearch}`, {
      cwd,
      encoding: 'utf8'
    });
    for (const line of String(log).split('\n')) {
      const pr = prFromCommitMessage(line.trim());
      if (pr) return pr;
    }
  } catch {
    return '';
  }
  return '';
}

/**
 * Resolve a PR number the way action-get-pr@v0.3.1 does.
 * @returns {Promise<{ pr?: string, source?: string, ignore?: boolean, message?: string, error?: string, exitCode?: number }>}
 */
async function resolvePrNumber({
  eventName,
  event = {},
  env = process.env,
  repository,
  token,
  sha,
  cwd = process.cwd(),
  fetchImpl = fetch,
  sleep,
  exec,
  exists,
  readFile
} = {}) {
  const name = eventName || '';
  const payload = event || {};
  const repo = repository || env.TEST_REPOSITORY || env.GITHUB_REPOSITORY || '';

  if (name === 'pull_request') {
    const pr = prNumberFromEvent('pull_request', payload, env);
    if (PR_RE.test(pr)) return { pr, source: 'event' };
    return { error: 'No valid PR number could be resolved for this event.', exitCode: 1 };
  }

  if (name === 'issues') {
    const titles = loadIgnoreTitles(cwd, exists || fs.existsSync, readFile || fs.readFileSync);
    const issueTitle = payload.issue && payload.issue.title;
    if (issueTitle) {
      for (const title of titles) {
        if (issueTitle.includes(title)) {
          return {
            ignore: true,
            exitCode: 0,
            message: `Ignore rule matched for "${title}". Skipping gracefully.`
          };
        }
      }
    }
    return { error: 'Standard issues do not have pull request numbers.', exitCode: 1 };
  }

  if (name === 'merge_group') {
    const pr = prNumberFromEvent('merge_group', payload, env);
    if (PR_RE.test(pr)) return { pr, source: 'event' };
    return { error: 'No valid PR number could be resolved for this event.', exitCode: 1 };
  }

  if (name === 'push' || name === 'release' || name === 'workflow_dispatch') {
    const commitSha = commitShaForEvent(name, payload, env, sha);
    let pr = '';
    if (commitSha && repo) {
      if (token) {
        pr = await fetchAssociatedPullNumber({
          repository: repo,
          sha: commitSha,
          token,
          fetchImpl,
          sleep
        });
        if (!pr) {
          pr = await fetchPrFromCommitMessage({
            repository: repo,
            sha: commitSha,
            token,
            fetchImpl
          });
        }
      }
      if (!pr) {
        pr = prFromLocalGitLog(name, cwd, exec || execSync, exists || fs.existsSync);
      }
    }
    if (PR_RE.test(pr)) return { pr, source: 'commit' };
    return { error: 'No valid PR number could be resolved for this event.', exitCode: 1 };
  }

  return { error: `Event type: unknown or unexpected event '${name}'`, exitCode: 1 };
}

module.exports = {
  prNumberFromEvent,
  prFromCommitMessage,
  loadIgnoreTitles,
  commitShaForEvent,
  pullsUrl,
  fetchAssociatedPullNumber,
  resolvePrNumber
};
