'use strict';
// Resolve a pull request number from the GitHub event or the commit, with no
// registry access. Used by image-tracker (outputs.pr, and when packages is
// omitted). This is the get-pr lookup, not a reason to deploy by PR tag.

const DEFAULT_USER_AGENT = 'bcgov-actions';
const API_VERSION = '2022-11-28';

/**
 * PR number from the workflow event, with no API call.
 * Covers pull_request, pull_request_target, and merge_group.
 * @param {string} eventName
 * @param {object} [event]
 * @param {NodeJS.ProcessEnv} [env]
 * @returns {string} PR number, or '' if this event has none
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
      (payload.merge_group && payload.merge_group.head_ref) ||
      env.MERGE_GROUP_HEAD_REF ||
      env.GITHUB_REF ||
      '';
    const match = String(headRef).match(/\/pr-(\d+)(?:-[0-9a-f]+)?$/);
    return match ? match[1] : '';
  }

  return '';
}

/**
 * Commit SHA to associate with a PR on push or release events.
 * @param {string} eventName
 * @param {object} [event]
 * @param {NodeJS.ProcessEnv} [env]
 * @returns {string}
 */
function commitShaFromEvent(eventName, event, env = process.env) {
  const payload = event || {};
  if (eventName === 'push') {
    return String(payload.after || env.GITHUB_SHA || '').trim();
  }
  if (eventName === 'release') {
    return String(env.GITHUB_SHA || '').trim();
  }
  return String(env.GITHUB_SHA || '').trim();
}

function pullsUrl(repository, sha) {
  return `https://api.github.com/repos/${repository}/commits/${sha}/pulls`;
}

/**
 * The merged PR associated with a commit, preferring the most recently merged.
 * @param {object[]} pulls
 * @returns {object|null}
 */
function pickMergedPull(pulls) {
  if (!Array.isArray(pulls) || pulls.length === 0) return null;
  const merged = pulls.filter((p) => p && p.number && (p.merged_at || p.merged === true));
  if (merged.length === 0) return null;
  merged.sort((a, b) => {
    const tb = Date.parse(b.merged_at || '') || 0;
    const ta = Date.parse(a.merged_at || '') || 0;
    if (tb !== ta) return tb - ta;
    return Number(b.number) - Number(a.number);
  });
  return merged[0];
}

/**
 * Associated PR for digest-path reuse: merged first, else the first numbered PR.
 * @param {object[]} pulls
 * @returns {object|null}
 */
function pickAssociatedPull(pulls) {
  return pickMergedPull(pulls) || (Array.isArray(pulls) ? pulls.find((p) => p && p.number) || null : null);
}

/**
 * List pull requests associated with a commit (GET /commits/{sha}/pulls).
 * @returns {Promise<{ pulls: object[], status: number, error?: string }>}
 */
async function listPullsForCommit({
  repository,
  sha,
  token,
  fetchImpl = fetch,
  userAgent = DEFAULT_USER_AGENT,
  retries = 1,
  timeoutMs = 0,
  sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
} = {}) {
  if (!repository || !sha) {
    return { pulls: [], status: 0, error: 'repository and sha are required' };
  }
  if (!token) {
    return {
      pulls: [],
      status: 0,
      error: 'A token with pull-requests: read is required to look up the PR for a commit.'
    };
  }

  const url = pullsUrl(repository, sha);
  const maxAttempts = Math.max(1, retries);
  let sleepMs = 2000;
  let lastStatus = 0;
  let lastError = '';

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    let timeoutId;
    try {
      const opts = {
        headers: {
          Accept: 'application/vnd.github+json',
          Authorization: `Bearer ${token}`,
          'X-GitHub-Api-Version': API_VERSION,
          'User-Agent': userAgent
        }
      };
      if (timeoutMs > 0) {
        const controller = new AbortController();
        timeoutId = setTimeout(() => controller.abort(), timeoutMs);
        opts.signal = controller.signal;
      }
      const res = await fetchImpl(url, opts);
      lastStatus = res.status;
      if (res.status === 200) {
        const body = await res.json();
        if (!Array.isArray(body)) {
          return { pulls: [], status: 200, error: 'Unexpected response from the pulls API.' };
        }
        if (body.length > 0 || attempt === maxAttempts) {
          return { pulls: body, status: 200 };
        }
        lastError = `No pull request associated with commit ${sha} yet.`;
      } else if (res.status === 401 || res.status === 403) {
        return {
          pulls: [],
          status: res.status,
          error: `GitHub API returned HTTP ${res.status} listing pulls for ${sha}. The token needs pull-requests: read.`
        };
      } else {
        lastError = `GitHub API returned HTTP ${res.status} listing pulls for ${sha}.`;
        if (attempt === maxAttempts) return { pulls: [], status: res.status, error: lastError };
      }
    } catch (err) {
      lastError = err?.message ?? String(err);
      if (attempt === maxAttempts) return { pulls: [], status: lastStatus, error: lastError };
    } finally {
      if (timeoutId) clearTimeout(timeoutId);
    }

    if (attempt < maxAttempts) {
      await sleep(sleepMs);
      sleepMs *= 2;
    }
  }

  return { pulls: [], status: lastStatus, error: lastError };
}

/**
 * Resolve a PR number using get-pr semantics, without registry work.
 * @returns {Promise<{ pr: string, source: 'event'|'commit'|'none', message?: string }>}
 */
async function resolvePrNumber({
  eventName,
  event = {},
  env = process.env,
  repository,
  token,
  fetchImpl = fetch,
  sleep
} = {}) {
  const fromEvent = prNumberFromEvent(eventName, event, env);
  if (fromEvent) return { pr: fromEvent, source: 'event' };

  if (eventName === 'pull_request' || eventName === 'pull_request_target') {
    return { pr: '', source: 'none', message: `No pull request number on this ${eventName} event.` };
  }
  if (eventName === 'merge_group') {
    const ref =
      (event && event.merge_group && event.merge_group.head_ref) ||
      env.MERGE_GROUP_HEAD_REF ||
      env.GITHUB_REF ||
      '';
    return {
      pr: '',
      source: 'none',
      message: `No pull request number on this merge_group event (ref was '${ref}').`
    };
  }
  if (eventName === 'push' || eventName === 'release') {
    const sha = commitShaFromEvent(eventName, event, env);
    if (!sha) {
      return { pr: '', source: 'none', message: `No commit SHA on this ${eventName} event.` };
    }
    if (!repository) {
      return {
        pr: '',
        source: 'none',
        message: `No repository available to look up the PR for commit ${sha}.`
      };
    }
    if (!token) {
      return {
        pr: '',
        source: 'none',
        message: `A token with pull-requests: read is required to look up the PR for commit ${sha}.`
      };
    }
    const { pulls, error } = await listPullsForCommit({
      repository,
      sha,
      token,
      fetchImpl,
      retries: 3,
      timeoutMs: 10000,
      sleep
    });
    const picked = pickMergedPull(pulls);
    if (picked) return { pr: String(picked.number), source: 'commit' };
    return {
      pr: '',
      source: 'none',
      message: error || `No merged pull request associated with commit ${sha}.`
    };
  }

  const label = eventName || 'unknown';
  return { pr: '', source: 'none', message: `No pull request number for event '${label}'.` };
}

module.exports = {
  prNumberFromEvent,
  commitShaFromEvent,
  pullsUrl,
  pickMergedPull,
  pickAssociatedPull,
  listPullsForCommit,
  resolvePrNumber
};
