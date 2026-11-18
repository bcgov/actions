const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { runMain } = require('../index.js');

const SHA = '7ba8a2cac4f6debe314be035a1ad4781bbc3df0d';

const ENV_KEYS = [
  'GITHUB_ACTIONS',
  'GITHUB_OUTPUT',
  'GITHUB_EVENT_PATH',
  'GITHUB_REPOSITORY',
  'GITHUB_EVENT_NAME',
  'GITHUB_REF',
  'GITHUB_SHA',
  'GITHUB_EVENT_NUMBER',
  'MERGE_GROUP_HEAD_REF',
  'INPUT_PACKAGES',
  'PACKAGES',
  'INPUT_REPOSITORY',
  'REPOSITORY',
  'INPUT_REVISION',
  'REVISION',
  'DIR',
  'INPUT_WORKING_DIRECTORY',
  'GITHUB_TOKEN',
  'GH_TOKEN',
  'INPUT_GITHUB_TOKEN',
  'TOKEN',
  'INPUT_TOKEN',
  'INPUT_TAGS',
  'GITHUB_STEP_SUMMARY'
];

function snapshotEnv() {
  const saved = {};
  for (const k of ENV_KEYS) saved[k] = process.env[k];
  saved._consoleLog = console.log;
  console.log = (...args) => {
    const line = args.join(' ');
    if (/^::(error|warning|group|endgroup)::/i.test(line)) return;
    saved._consoleLog(...args);
  };
  delete process.env.GITHUB_STEP_SUMMARY;
  return saved;
}

function restoreEnv(saved) {
  if (saved._consoleLog) console.log = saved._consoleLog;
  for (const [k, v] of Object.entries(saved)) {
    if (k === '_consoleLog') continue;
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
}

function parseOutputs(file) {
  const out = {};
  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    if (!line) continue;
    const i = line.indexOf('=');
    if (i === -1) continue;
    // Last assignment wins, matching GitHub's GITHUB_OUTPUT behaviour
    out[line.slice(0, i)] = line.slice(i + 1);
  }
  return out;
}

async function withRunMain(setup) {
  const saved = snapshotEnv();
  const cwd = process.cwd();
  const origExit = process.exit;
  const origFetch = global.fetch;
  let exitCode;
  process.exit = (code) => {
    exitCode = code;
    throw new Error('__exit__');
  };
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tracker-pr-'));
  try {
    const result = await setup({ dir, saved });
    return { ...result, exitCode, dir };
  } finally {
    process.exit = origExit;
    global.fetch = origFetch;
    process.chdir(cwd);
    restoreEnv(saved);
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

function writeEvent(dir, event) {
  const eventPath = path.join(dir, 'event.json');
  fs.writeFileSync(eventPath, JSON.stringify(event));
  return eventPath;
}

test('runMain PR-only: pull_request returns the event number with no registry or git repo', async () => {
  const fetches = [];
  const { exitCode, outputs } = await withRunMain(async ({ dir }) => {
    const out = path.join(dir, 'github_output');
    // Empty scratch directory — no .git — and no packages
    process.env.GITHUB_ACTIONS = 'true';
    process.env.GITHUB_OUTPUT = out;
    process.env.GITHUB_EVENT_PATH = writeEvent(dir, { pull_request: { number: 475 } });
    process.env.GITHUB_EVENT_NAME = 'pull_request';
    process.env.GITHUB_REPOSITORY = 'bcgov/nr-epd-organics-info';
    delete process.env.INPUT_PACKAGES;
    delete process.env.PACKAGES;
    delete process.env.INPUT_TAGS;
    delete process.env.INPUT_WORKING_DIRECTORY;
    delete process.env.DIR;
    delete process.env.INPUT_TOKEN;
    global.fetch = async (url) => {
      fetches.push(url);
      throw new Error(`unexpected fetch: ${url}`);
    };
    await runMain();
    return { outputs: parseOutputs(out) };
  });
  assert.strictEqual(exitCode, undefined, 'PR-only mode should not exit');
  assert.strictEqual(outputs.pr, '475');
  assert.strictEqual(outputs.image, '');
  assert.strictEqual(outputs.digest, '');
  assert.strictEqual(outputs.digests, '{}');
  assert.deepStrictEqual(fetches, []);
});

test('runMain PR-only: pull_request_target and merge_group', async () => {
  await withRunMain(async ({ dir }) => {
    const out = path.join(dir, 'github_output');
    process.env.GITHUB_ACTIONS = 'true';
    process.env.GITHUB_OUTPUT = out;
    process.env.GITHUB_EVENT_PATH = writeEvent(dir, { pull_request: { number: 1240 } });
    process.env.GITHUB_EVENT_NAME = 'pull_request_target';
    process.env.GITHUB_REPOSITORY = 'bcgov/foo';
    delete process.env.INPUT_PACKAGES;
    delete process.env.PACKAGES;
    global.fetch = async () => {
      throw new Error('no fetch');
    };
    await runMain();
    assert.strictEqual(parseOutputs(out).pr, '1240');
  });

  await withRunMain(async ({ dir }) => {
    const out = path.join(dir, 'github_output');
    process.env.GITHUB_ACTIONS = 'true';
    process.env.GITHUB_OUTPUT = out;
    process.env.GITHUB_EVENT_PATH = writeEvent(dir, {
      merge_group: { head_ref: 'refs/heads/gh-readonly-queue/main/pr-2904-abcdef' }
    });
    process.env.GITHUB_EVENT_NAME = 'merge_group';
    process.env.GITHUB_REPOSITORY = 'bcgov/foo';
    delete process.env.INPUT_PACKAGES;
    delete process.env.PACKAGES;
    global.fetch = async () => {
      throw new Error('no fetch');
    };
    await runMain();
    assert.strictEqual(parseOutputs(out).pr, '2904');
  });
});

test('runMain PR-only: push queries /commits/{sha}/pulls and picks the merged PR', async () => {
  const urls = [];
  const { outputs } = await withRunMain(async ({ dir }) => {
    const out = path.join(dir, 'github_output');
    process.env.GITHUB_ACTIONS = 'true';
    process.env.GITHUB_OUTPUT = out;
    process.env.GITHUB_EVENT_PATH = writeEvent(dir, { after: SHA });
    process.env.GITHUB_EVENT_NAME = 'push';
    process.env.GITHUB_REPOSITORY = 'bcgov/quickstart-openshift';
    process.env.INPUT_TOKEN = 'test-token';
    delete process.env.INPUT_PACKAGES;
    delete process.env.PACKAGES;
    global.fetch = async (url) => {
      urls.push(url);
      assert.ok(!String(url).includes('ghcr.io'), `registry must not be contacted: ${url}`);
      return {
        status: 200,
        json: async () => [
          { number: 1, merged_at: null },
          { number: 31, merged_at: '2026-11-01T00:00:00Z' }
        ]
      };
    };
    await runMain();
    return { outputs: parseOutputs(out) };
  });
  assert.deepStrictEqual(urls, [
    `https://api.github.com/repos/bcgov/quickstart-openshift/commits/${SHA}/pulls`
  ]);
  assert.strictEqual(outputs.pr, '31');
});

test('runMain PR-only: unknown event leaves pr empty and does not fail', async () => {
  const logs = [];
  const { exitCode, outputs } = await withRunMain(async ({ dir }) => {
    const out = path.join(dir, 'github_output');
    process.env.GITHUB_ACTIONS = 'true';
    process.env.GITHUB_OUTPUT = out;
    process.env.GITHUB_EVENT_PATH = writeEvent(dir, {});
    process.env.GITHUB_EVENT_NAME = 'workflow_dispatch';
    process.env.GITHUB_REPOSITORY = 'bcgov/foo';
    delete process.env.INPUT_PACKAGES;
    delete process.env.PACKAGES;
    const origError = console.error;
    console.error = (...args) => logs.push(args.join(' '));
    try {
      await runMain();
    } finally {
      console.error = origError;
    }
    return { outputs: parseOutputs(out) };
  });
  assert.strictEqual(exitCode, undefined);
  assert.strictEqual(outputs.pr, '');
  assert.ok(
    logs.some((l) => /No pull request number for event 'workflow_dispatch'/.test(l)),
    `expected a clear message, got: ${logs.join('\n')}`
  );
});

test('runMain PR-only: tags without packages exits 1', async () => {
  const { exitCode } = await withRunMain(async ({ dir }) => {
    process.env.GITHUB_ACTIONS = 'true';
    process.env.GITHUB_OUTPUT = path.join(dir, 'github_output');
    process.env.GITHUB_EVENT_PATH = writeEvent(dir, { pull_request: { number: 1 } });
    process.env.GITHUB_EVENT_NAME = 'pull_request';
    process.env.GITHUB_REPOSITORY = 'bcgov/foo';
    process.env.INPUT_TAGS = 'latest';
    process.env.INPUT_TOKEN = 't';
    delete process.env.INPUT_PACKAGES;
    delete process.env.PACKAGES;
    await assert.rejects(() => runMain(), /__exit__/);
  });
  assert.strictEqual(exitCode, 1);
});

test('runMain with packages: pull_request pr output is the event number, not the digest hit PR', async () => {
  const repoDir = fs.mkdtempSync(path.join(os.tmpdir(), 'tracker-pr-digest-'));
  const saved = snapshotEnv();
  const cwd = process.cwd();
  const origFetch = global.fetch;
  const origExit = process.exit;
  try {
    process.exit = (code) => {
      throw new Error(`process.exit called with code ${code}`);
    };

    execFileSync('git', ['init', '-b', 'main'], { cwd: repoDir, stdio: 'ignore' });
    execFileSync('git', ['config', 'user.name', 'Test'], { cwd: repoDir, stdio: 'ignore' });
    execFileSync('git', ['config', 'user.email', 'test@example.com'], { cwd: repoDir, stdio: 'ignore' });
    fs.writeFileSync(path.join(repoDir, 'app.txt'), 'app\n');
    execFileSync('git', ['add', '.'], { cwd: repoDir, stdio: 'ignore' });
    execFileSync('git', ['commit', '-m', 'initial'], { cwd: repoDir, stdio: 'ignore' });
    const headSha = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: repoDir, encoding: 'utf8' }).trim();

    const expectedDigest = 'sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
    global.fetch = async (url) => {
      if (String(url).endsWith('/manifests/latest')) {
        return {
          ok: false,
          status: 401,
          headers: {
            get: (h) =>
              h.toLowerCase() === 'www-authenticate'
                ? 'Bearer realm="https://ghcr.io/token",service="ghcr.io"'
                : null
          },
          json: async () => ({})
        };
      }
      if (String(url).includes('/token?')) {
        return {
          ok: true,
          status: 200,
          headers: { get: () => null },
          json: async () => ({ token: 'mock-token' })
        };
      }
      if (String(url).includes('/manifests/')) {
        return {
          ok: true,
          status: 200,
          headers: {
            get: (h) => (h.toLowerCase() === 'docker-content-digest' ? expectedDigest : null)
          },
          json: async () => ({
            mediaType: 'application/vnd.oci.image.manifest.v1+json',
            digest: expectedDigest,
            annotations: {
              'org.opencontainers.image.revision': headSha,
              'org.opencontainers.image.source': 'https://github.com/bcgov/quickstart-openshift',
              'org.opencontainers.image.created': '2026-11-17T00:00:00Z'
            }
          })
        };
      }
      return { ok: false, status: 404, headers: { get: () => null }, json: async () => ({}) };
    };

    const out = path.join(repoDir, 'github_output');
    const eventPath = path.join(repoDir, 'event.json');
    fs.writeFileSync(
      eventPath,
      JSON.stringify({
        pull_request: { number: 383, head: { sha: headSha }, title: 'feature' }
      })
    );

    process.env.GITHUB_ACTIONS = 'true';
    process.env.GITHUB_REPOSITORY = 'bcgov/quickstart-openshift';
    process.env.GITHUB_OUTPUT = out;
    process.env.GITHUB_EVENT_PATH = eventPath;
    process.env.GITHUB_EVENT_NAME = 'pull_request';
    process.env.INPUT_PACKAGES = 'frontend';
    process.env.PACKAGES = 'frontend';
    process.env.INPUT_REPOSITORY = 'bcgov/quickstart-openshift';
    process.env.REPOSITORY = 'bcgov/quickstart-openshift';
    process.env.INPUT_REVISION = headSha;
    process.env.REVISION = headSha;
    process.env.DIR = repoDir;
    process.env.INPUT_WORKING_DIRECTORY = repoDir;
    delete process.env.INPUT_TOKEN;
    delete process.env.GITHUB_TOKEN;
    delete process.env.TOKEN;

    await runMain();

    const outputs = parseOutputs(out);
    assert.strictEqual(outputs.digest, expectedDigest, 'digest resolution is unchanged');
    assert.strictEqual(
      outputs.image,
      `ghcr.io/bcgov/quickstart-openshift/frontend@${expectedDigest}`
    );
    assert.strictEqual(outputs.pr, '383', 'pr comes from the event, not the image hit');
  } finally {
    global.fetch = origFetch;
    process.exit = origExit;
    process.chdir(cwd);
    restoreEnv(saved);
    fs.rmSync(repoDir, { recursive: true, force: true });
  }
});
