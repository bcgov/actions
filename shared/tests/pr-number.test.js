const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const {
  prNumberFromEvent,
  prFromCommitMessage,
  loadIgnoreTitles,
  commitShaForEvent,
  pullsUrl,
  fetchAssociatedPullNumber,
  resolvePrNumber
} = require('../pr-number.js');

const SHA = '7ba8a2cac4f6debe314be035a1ad4781bbc3df0d';

function repoWithCommit(subject) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'get-pr-git-'));
  execFileSync('git', ['init', '-q'], { cwd: dir });
  execFileSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '--allow-empty', '-m', subject], {
    cwd: dir
  });
  return dir;
}

test('prNumberFromEvent: pull_request uses payload.pull_request.number, then number, then GITHUB_EVENT_NUMBER', () => {
  assert.strictEqual(prNumberFromEvent('pull_request', { pull_request: { number: 42 }, number: 7 }), '42');
  assert.strictEqual(prNumberFromEvent('pull_request', { number: 7 }), '7');
  assert.strictEqual(prNumberFromEvent('pull_request', {}, { GITHUB_EVENT_NUMBER: '12' }), '12');
  assert.strictEqual(prNumberFromEvent('pull_request', {}), '');
});

test('prNumberFromEvent: pull_request_target shares the payload shape (digest fast path only)', () => {
  assert.strictEqual(prNumberFromEvent('pull_request_target', { pull_request: { number: 1240 } }), '1240');
});

test('prNumberFromEvent: merge_group parses current and legacy queue refs, not GITHUB_REF', () => {
  assert.strictEqual(
    prNumberFromEvent('merge_group', {
      merge_group: { head_ref: 'refs/heads/gh-readonly-queue/main/pr-123-0123abcd' }
    }),
    '123'
  );
  assert.strictEqual(prNumberFromEvent('merge_group', { merge_group: { head_ref: 'queue/main/pr-55' } }), '55');
  assert.strictEqual(
    prNumberFromEvent('merge_group', {}, { MERGE_GROUP_HEAD_REF: 'queue/main/pr-9' }),
    '9'
  );
  assert.strictEqual(
    prNumberFromEvent('merge_group', {}, { GITHUB_REF: 'refs/heads/gh-readonly-queue/main/pr-7-deadbeef' }),
    '',
    'get-pr does not read GITHUB_REF'
  );
});

test('prFromCommitMessage: squash, merge, and general PR mention', () => {
  assert.strictEqual(prFromCommitMessage('feat: thing (#88)'), '88');
  assert.strictEqual(prFromCommitMessage('Merge pull request #19 from bcgov/feat/x'), '19');
  assert.strictEqual(prFromCommitMessage('chore: follow-up to PR #31'), '31');
  assert.strictEqual(prFromCommitMessage('chore: direct push'), '');
});

test('loadIgnoreTitles: defaults, then rules.yml', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'get-pr-rules-'));
  assert.deepStrictEqual(loadIgnoreTitles(dir), ['Dependency Dashboard', 'ZAP Security Report']);
  fs.writeFileSync(path.join(dir, 'rules.yml'), 'ignore_issues:\n  - "Weekly Report"\n');
  assert.deepStrictEqual(loadIgnoreTitles(dir), ['Weekly Report']);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('commitShaForEvent: push uses after, release uses GITHUB_SHA', () => {
  assert.strictEqual(commitShaForEvent('push', { after: SHA }), SHA);
  assert.strictEqual(commitShaForEvent('release', {}, { GITHUB_SHA: 'abc' }), 'abc');
});

test('pullsUrl points at the commits/{sha}/pulls API', () => {
  assert.strictEqual(
    pullsUrl('bcgov/quickstart-openshift', SHA),
    `https://api.github.com/repos/bcgov/quickstart-openshift/commits/${SHA}/pulls`
  );
});

test('resolvePrNumber: pull_request from payload, no fetch', async () => {
  const pr = await resolvePrNumber({
    eventName: 'pull_request',
    event: { pull_request: { number: 42 } },
    fetchImpl: async () => {
      throw new Error('no fetch on a pull_request event');
    }
  });
  assert.deepStrictEqual({ pr: pr.pr, source: pr.source }, { pr: '42', source: 'event' });
});

test('resolvePrNumber: pull_request_target is unknown (get-pr does not handle it)', async () => {
  const result = await resolvePrNumber({
    eventName: 'pull_request_target',
    event: { pull_request: { number: 1240 } }
  });
  assert.strictEqual(result.exitCode, 1);
  assert.match(result.error, /unknown or unexpected event 'pull_request_target'/);
});

test('resolvePrNumber: merge_group current and legacy refs', async () => {
  const cur = await resolvePrNumber({
    eventName: 'merge_group',
    event: { merge_group: { head_ref: 'refs/heads/gh-readonly-queue/main/pr-123-0123abcd' } }
  });
  assert.strictEqual(cur.pr, '123');
  const old = await resolvePrNumber({
    eventName: 'merge_group',
    event: { merge_group: { head_ref: 'queue/main/pr-55' } }
  });
  assert.strictEqual(old.pr, '55');
});

test('resolvePrNumber: push uses body[0] from the pulls API, not a merged-only pick', async () => {
  const result = await resolvePrNumber({
    eventName: 'push',
    event: { after: SHA },
    repository: 'bcgov/quickstart-openshift',
    token: 't',
    sleep: async () => {},
    fetchImpl: async () => ({
      status: 200,
      json: async () => [
        { number: 10, merged_at: null },
        { number: 31, merged_at: '2026-11-01T00:00:00Z' }
      ]
    })
  });
  assert.strictEqual(result.pr, '10', 'get-pr uses body[0]');
});

test('fetchAssociatedPullNumber retries empty 200 responses then returns body[0]', async () => {
  const sleeps = [];
  let attempt = 0;
  const pr = await fetchAssociatedPullNumber({
    repository: 'bcgov/foo',
    sha: SHA,
    token: 't',
    sleep: async (ms) => {
      sleeps.push(ms);
    },
    fetchImpl: async () => {
      attempt += 1;
      if (attempt < 3) return { status: 200, json: async () => [] };
      return { status: 200, json: async () => [{ number: 99 }] };
    }
  });
  assert.strictEqual(pr, '99');
  assert.deepStrictEqual(sleeps, [2000, 4000]);
});

test('resolvePrNumber: 401 on pulls falls through to the commit-message tier', async () => {
  const urls = [];
  const result = await resolvePrNumber({
    eventName: 'push',
    event: { after: SHA },
    repository: 'bcgov/foo',
    token: 't',
    sleep: async () => {
      throw new Error('should not retry 401');
    },
    fetchImpl: async (url) => {
      urls.push(url);
      if (String(url).endsWith('/pulls')) return { status: 401, json: async () => ({}) };
      return {
        status: 200,
        json: async () => ({ commit: { message: 'feat: thing (#88)' } })
      };
    }
  });
  assert.strictEqual(result.pr, '88');
  assert.ok(urls.some((u) => String(u).endsWith(`/${SHA}`)));
});

test('resolvePrNumber: release reads GITHUB_SHA and the pulls API', async () => {
  const result = await resolvePrNumber({
    eventName: 'release',
    event: {},
    env: { GITHUB_SHA: SHA },
    repository: 'bcgov/foo',
    token: 't',
    sleep: async () => {},
    fetchImpl: async () => ({ status: 200, json: async () => [{ number: 8 }] })
  });
  assert.strictEqual(result.pr, '8');
});

test('resolvePrNumber: push squash subject from local git history when there is no token', async () => {
  const cwd = repoWithCommit('feat: thing (#88)');
  try {
    const result = await resolvePrNumber({
      eventName: 'push',
      event: { after: 'abc123' },
      repository: 'bcgov/example',
      cwd,
      fetchImpl: async () => {
        throw new Error('no fetch without a token');
      }
    });
    assert.strictEqual(result.pr, '88');
  } finally {
    fs.rmSync(cwd, { recursive: true, force: true });
  }
});

test('resolvePrNumber: release merge subject from local git history', async () => {
  const cwd = repoWithCommit('Merge pull request #19 from bcgov/feat/x');
  try {
    const result = await resolvePrNumber({
      eventName: 'release',
      event: {},
      env: { GITHUB_SHA: 'abc123' },
      repository: 'bcgov/example',
      cwd
    });
    assert.strictEqual(result.pr, '19');
  } finally {
    fs.rmSync(cwd, { recursive: true, force: true });
  }
});

test('resolvePrNumber: workflow_dispatch general PR mention from local git history', async () => {
  const cwd = repoWithCommit('chore: follow-up to PR #31');
  try {
    const result = await resolvePrNumber({
      eventName: 'workflow_dispatch',
      event: {},
      env: { GITHUB_SHA: 'abc123' },
      repository: 'bcgov/example',
      cwd
    });
    assert.strictEqual(result.pr, '31');
  } finally {
    fs.rmSync(cwd, { recursive: true, force: true });
  }
});

test('resolvePrNumber: push with no PR found is an error', async () => {
  const cwd = repoWithCommit('chore: direct push');
  try {
    const result = await resolvePrNumber({
      eventName: 'push',
      event: { after: 'abc123' },
      repository: 'bcgov/example',
      cwd,
      sleep: async () => {},
      fetchImpl: async () => ({ status: 200, json: async () => [] })
    });
    assert.strictEqual(result.exitCode, 1);
    assert.match(result.error, /No valid PR number could be resolved/);
  } finally {
    fs.rmSync(cwd, { recursive: true, force: true });
  }
});

test('resolvePrNumber: issues ignored title exits 0 with no PR', async () => {
  const result = await resolvePrNumber({
    eventName: 'issues',
    event: { issue: { title: 'Dependency Dashboard' } },
    cwd: fs.mkdtempSync(path.join(os.tmpdir(), 'get-pr-iss-'))
  });
  assert.strictEqual(result.exitCode, 0);
  assert.strictEqual(result.ignore, true);
  assert.ok(!result.pr);
});

test('resolvePrNumber: issues other title fails', async () => {
  const result = await resolvePrNumber({
    eventName: 'issues',
    event: { issue: { title: 'Bug report' } },
    cwd: fs.mkdtempSync(path.join(os.tmpdir(), 'get-pr-iss-'))
  });
  assert.strictEqual(result.exitCode, 1);
  assert.match(result.error, /Standard issues do not have pull request numbers/);
});

test('resolvePrNumber: unknown event fails', async () => {
  const result = await resolvePrNumber({ eventName: 'schedule', event: {} });
  assert.strictEqual(result.exitCode, 1);
  assert.match(result.error, /unknown or unexpected event 'schedule'/);
});
