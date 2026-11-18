const test = require('node:test');
const assert = require('node:assert');
const {
  prNumberFromEvent,
  commitShaFromEvent,
  pullsUrl,
  pickMergedPull,
  pickAssociatedPull,
  listPullsForCommit,
  resolvePrNumber
} = require('../pr-number.js');

const SHA = '7ba8a2cac4f6debe314be035a1ad4781bbc3df0d';

test('prNumberFromEvent: pull_request uses payload.pull_request.number', () => {
  assert.strictEqual(
    prNumberFromEvent('pull_request', { pull_request: { number: 31 }, number: 99 }),
    '31'
  );
});

test('prNumberFromEvent: pull_request falls back to payload.number then GITHUB_EVENT_NUMBER', () => {
  assert.strictEqual(prNumberFromEvent('pull_request', { number: 475 }), '475');
  assert.strictEqual(prNumberFromEvent('pull_request', {}, { GITHUB_EVENT_NUMBER: '12' }), '12');
  assert.strictEqual(prNumberFromEvent('pull_request', {}), '');
});

test('prNumberFromEvent: pull_request_target is the same as pull_request', () => {
  assert.strictEqual(
    prNumberFromEvent('pull_request_target', { pull_request: { number: 1240 } }),
    '1240'
  );
});

test('prNumberFromEvent: merge_group parses current and legacy queue refs', () => {
  assert.strictEqual(
    prNumberFromEvent('merge_group', {
      merge_group: { head_ref: 'refs/heads/gh-readonly-queue/main/pr-88-aabbccddeeff0011' }
    }),
    '88'
  );
  assert.strictEqual(
    prNumberFromEvent('merge_group', { merge_group: { head_ref: 'queue/main/pr-42' } }),
    '42'
  );
  assert.strictEqual(
    prNumberFromEvent('merge_group', {}, { GITHUB_REF: 'refs/heads/gh-readonly-queue/main/pr-7-deadbeef' }),
    '7'
  );
  assert.strictEqual(prNumberFromEvent('merge_group', { merge_group: { head_ref: 'main' } }), '');
});

test('prNumberFromEvent: push and other events are empty (no API)', () => {
  assert.strictEqual(prNumberFromEvent('push', { after: SHA }), '');
  assert.strictEqual(prNumberFromEvent('release', {}), '');
  assert.strictEqual(prNumberFromEvent('workflow_dispatch', {}), '');
  assert.strictEqual(prNumberFromEvent('', {}), '');
});

test('commitShaFromEvent: push uses after, then GITHUB_SHA', () => {
  assert.strictEqual(commitShaFromEvent('push', { after: SHA }), SHA);
  assert.strictEqual(commitShaFromEvent('push', {}, { GITHUB_SHA: 'abc' }), 'abc');
  assert.strictEqual(commitShaFromEvent('release', {}, { GITHUB_SHA: SHA }), SHA);
});

test('pullsUrl points at the commits/{sha}/pulls API', () => {
  assert.strictEqual(
    pullsUrl('bcgov/quickstart-openshift', SHA),
    `https://api.github.com/repos/bcgov/quickstart-openshift/commits/${SHA}/pulls`
  );
});

test('pickMergedPull prefers the most recently merged PR', () => {
  const pulled = pickMergedPull([
    { number: 10, merged_at: '2026-01-01T00:00:00Z' },
    { number: 11, merged_at: null },
    { number: 12, merged_at: '2026-02-01T00:00:00Z' }
  ]);
  assert.strictEqual(pulled.number, 12);
  assert.strictEqual(pickMergedPull([{ number: 3 }]), null);
  assert.strictEqual(pickMergedPull([]), null);
});

test('pickAssociatedPull falls back to the first numbered PR when none are merged', () => {
  assert.strictEqual(pickAssociatedPull([{ number: 4 }, { number: 5 }]).number, 4);
  assert.strictEqual(pickAssociatedPull([{ number: 9, merged_at: '2026-03-01T00:00:00Z' }]).number, 9);
  assert.strictEqual(pickAssociatedPull([]), null);
});

test('listPullsForCommit: success, 401, and empty last attempt', async () => {
  const calls = [];
  const ok = await listPullsForCommit({
    repository: 'bcgov/foo',
    sha: SHA,
    token: 't',
    retries: 1,
    fetchImpl: async (url, opts) => {
      calls.push({ url, auth: opts.headers.Authorization });
      return { status: 200, json: async () => [{ number: 31, merged_at: '2026-01-01T00:00:00Z' }] };
    }
  });
  assert.strictEqual(ok.pulls[0].number, 31);
  assert.ok(calls[0].url.endsWith(`/commits/${SHA}/pulls`));
  assert.strictEqual(calls[0].auth, 'Bearer t');

  const denied = await listPullsForCommit({
    repository: 'bcgov/foo',
    sha: SHA,
    token: 't',
    retries: 3,
    sleep: async () => {
      throw new Error('should not retry 401');
    },
    fetchImpl: async () => ({ status: 401, json: async () => ({}) })
  });
  assert.strictEqual(denied.status, 401);
  assert.match(denied.error, /pull-requests: read/);

  const missing = await listPullsForCommit({
    repository: 'bcgov/foo',
    sha: SHA,
    token: '',
    fetchImpl: async () => {
      throw new Error('should not fetch without a token');
    }
  });
  assert.strictEqual(missing.pulls.length, 0);
  assert.match(missing.error, /token/);
});

test('listPullsForCommit retries empty 200 responses (indexing lag)', async () => {
  const sleeps = [];
  let attempt = 0;
  const res = await listPullsForCommit({
    repository: 'bcgov/foo',
    sha: SHA,
    token: 't',
    retries: 3,
    sleep: async (ms) => {
      sleeps.push(ms);
    },
    fetchImpl: async () => {
      attempt += 1;
      if (attempt < 3) return { status: 200, json: async () => [] };
      return { status: 200, json: async () => [{ number: 99, merged_at: '2026-04-01T00:00:00Z' }] };
    }
  });
  assert.strictEqual(res.pulls[0].number, 99);
  assert.deepStrictEqual(sleeps, [2000, 4000]);
});

test('resolvePrNumber: event path does not fetch', async () => {
  const pr = await resolvePrNumber({
    eventName: 'pull_request',
    event: { pull_request: { number: 475 } },
    fetchImpl: async () => {
      throw new Error('no fetch on a pull_request event');
    }
  });
  assert.deepStrictEqual(pr, { pr: '475', source: 'event' });
});

test('resolvePrNumber: push picks the merged PR and ignores open ones', async () => {
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
        { number: 31, merged_at: '2026-05-01T00:00:00Z' }
      ]
    })
  });
  assert.deepStrictEqual(result, { pr: '31', source: 'commit' });
});

test('resolvePrNumber: release uses GITHUB_SHA', async () => {
  const result = await resolvePrNumber({
    eventName: 'release',
    event: {},
    env: { GITHUB_SHA: SHA },
    repository: 'bcgov/foo',
    token: 't',
    sleep: async () => {},
    fetchImpl: async () => ({
      status: 200,
      json: async () => [{ number: 8, merged: true, merged_at: '2026-06-01T00:00:00Z' }]
    })
  });
  assert.deepStrictEqual(result, { pr: '8', source: 'commit' });
});

test('resolvePrNumber: otherwise empty with a clear message', async () => {
  const wf = await resolvePrNumber({
    eventName: 'workflow_dispatch',
    event: {},
    fetchImpl: async () => {
      throw new Error('no fetch');
    }
  });
  assert.strictEqual(wf.pr, '');
  assert.strictEqual(wf.source, 'none');
  assert.match(wf.message, /workflow_dispatch/);

  const issues = await resolvePrNumber({ eventName: 'issues', event: { issue: { number: 1 } } });
  assert.strictEqual(issues.pr, '');
  assert.match(issues.message, /issues/);

  const noMerged = await resolvePrNumber({
    eventName: 'push',
    event: { after: SHA },
    repository: 'bcgov/foo',
    token: 't',
    sleep: async () => {},
    fetchImpl: async () => ({ status: 200, json: async () => [{ number: 4, merged_at: null }] })
  });
  assert.strictEqual(noMerged.pr, '');
  assert.match(noMerged.message, /No merged pull request associated with commit/);
});
