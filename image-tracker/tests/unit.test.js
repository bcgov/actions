const test = require('node:test');
const assert = require('node:assert');
const { execSync, execFileSync } = require('node:child_process');
const {
  mapPackages,
  parseAuthHeader,
  matchesCandidate,
  renderStepSummary,
  extractPrNumber
} = require('../index.js');

test('Package mapping - single package nested', () => {
  const { imagePaths } = mapPackages('frontend', 'bcgov/quickstart-openshift');
  assert.strictEqual(Object.keys(imagePaths).length, 1, 'single package count');
  assert.strictEqual(
    imagePaths['frontend'],
    'bcgov/quickstart-openshift/frontend',
    'nested path when package != repo'
  );
});

test('Package mapping - single package repo root', () => {
  const { imagePaths } = mapPackages('vexilon', 'MinionTech/vexilon');
  assert.strictEqual(Object.keys(imagePaths).length, 1, 'repo-root package count');
  assert.strictEqual(
    imagePaths['vexilon'],
    'miniontech/vexilon',
    'root path when package == repo (case-insensitive)'
  );
});

test('Package mapping - multiple packages comma', () => {
  const { imagePaths } = mapPackages('frontend, backend, migrations', 'bcgov/quickstart-openshift');
  assert.strictEqual(Object.keys(imagePaths).length, 3, 'three packages');
  assert.strictEqual(imagePaths['frontend'], 'bcgov/quickstart-openshift/frontend', 'frontend path');
  assert.strictEqual(imagePaths['backend'], 'bcgov/quickstart-openshift/backend', 'backend path');
  assert.strictEqual(imagePaths['migrations'], 'bcgov/quickstart-openshift/migrations', 'migrations path');
});

test('Package mapping - multiple packages newline', () => {
  const { imagePaths } = mapPackages('api\nfrontend\ndb', 'bcgov/myapp');
  assert.strictEqual(Object.keys(imagePaths).length, 3, 'three packages from newlines');
  assert.strictEqual(imagePaths['api'], 'bcgov/myapp/api', 'api path');
  assert.strictEqual(imagePaths['frontend'], 'bcgov/myapp/frontend', 'frontend path');
  assert.strictEqual(imagePaths['db'], 'bcgov/myapp/db', 'db path');
});

test('Package mapping - case normalization', () => {
  const { imagePaths } = mapPackages('Frontend, QUICKSTART-Openshift', 'BCGov/Quickstart-Openshift');
  assert.strictEqual(
    imagePaths['Frontend'],
    'bcgov/quickstart-openshift/frontend',
    'image path is lowercased regardless of input case'
  );
  assert.strictEqual(
    imagePaths['QUICKSTART-Openshift'],
    'bcgov/quickstart-openshift',
    'repo-root match is case-insensitive'
  );
});

test('Package mapping - empty input rejected', () => {
  const { imagePaths } = mapPackages('', 'bcgov/myapp');
  assert.strictEqual(Object.keys(imagePaths).length, 0, 'empty input yields no packages');
});

test('Package mapping - whitespace-only entries ignored', () => {
  const { imagePaths } = mapPackages('  ,frontend,   ,backend  ,', 'bcgov/myapp');
  assert.strictEqual(Object.keys(imagePaths).length, 2, 'whitespace-only entries are skipped');
  assert.strictEqual(imagePaths['frontend'], 'bcgov/myapp/frontend', 'frontend retained');
  assert.strictEqual(imagePaths['backend'], 'bcgov/myapp/backend', 'backend retained');
});

test('Package mapping - space separated packages', () => {
  const { imagePaths } = mapPackages('frontend backend migrations', 'bcgov/myapp');
  assert.strictEqual(Object.keys(imagePaths).length, 3, 'space-separated: correct package count');
  assert.strictEqual(imagePaths['frontend'], 'bcgov/myapp/frontend', 'space-separated: frontend path');
  assert.strictEqual(imagePaths['backend'], 'bcgov/myapp/backend', 'space-separated: backend path');
  assert.strictEqual(imagePaths['migrations'], 'bcgov/myapp/migrations', 'space-separated: migrations path');
});

test('Git plumbing sanity - HEAD resolution', () => {
  let sha = '';
  try {
    sha = execFileSync('git', ['-c', 'safe.directory=*', 'rev-parse', '--verify', '--quiet', 'HEAD'], { encoding: 'utf8', stdio: ['pipe', 'pipe', 'ignore'] }).trim();
  } catch (err) {}
  if (!sha) {
    try {
      sha = execFileSync('git', ['rev-parse', '--verify', '--quiet', 'HEAD'], { encoding: 'utf8', stdio: ['pipe', 'pipe', 'ignore'] }).trim();
    } catch (err) {}
  }
  const ok = /^[a-f0-9]{40}$/.test(sha);
  assert.strictEqual(ok, true, 'HEAD resolves to a 40-char commit SHA');
});

test('PR extraction from payload', () => {
  const payload = 'abc1234|sha256:1234567890|2026-01-01T00:00:00Z|42|Fix something';
  const rPr = extractPrNumber(payload);
  assert.strictEqual(rPr, '42', 'PR number extracted from payload');

  const emptyPayload = 'abc1234|sha256:1234567890|2026-01-01T00:00:00Z||Fix something';
  const rPrEmpty = extractPrNumber(emptyPayload);
  assert.strictEqual(rPrEmpty, '', 'Empty PR number handled cleanly');
});

test('Candidate matching - PR tag isolation', () => {
  const candidates = [
    '1111111111111111111111111111111111111111',
    '2222222222222222222222222222222222222222'
  ];
  const prMap = {};
  const prNumMap = {
    '2222222222222222222222222222222222222222': '99'
  };

  const matchCand2 = matchesCandidate('', 'pr-99', candidates, prMap, prNumMap);
  assert.strictEqual(matchCand2, true, 'matches_candidate succeeds for registered PR tag');

  const matchUnregistered = matchesCandidate('', 'pr-100', candidates, prMap, prNumMap);
  assert.strictEqual(matchUnregistered, false, 'matches_candidate rejects unregistered PR tag');
});

test('Www-Authenticate header parsing - GHCR', () => {
  const parsed = parseAuthHeader(
    'www-authenticate: Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="repository:user/image:pull"'
  );
  assert.strictEqual(parsed.realm, 'https://ghcr.io/token', 'parse auth header for GHCR realm');
  assert.strictEqual(parsed.service, 'ghcr.io', 'parse auth header for GHCR service');
});

test('Www-Authenticate header parsing - Docker Hub', () => {
  const parsed = parseAuthHeader(
    'WWW-Authenticate: Bearer realm="https://auth.docker.io/token",service="registry.docker.io"'
  );
  assert.strictEqual(parsed.realm, 'https://auth.docker.io/token', 'parse auth header for Docker Hub realm');
  assert.strictEqual(parsed.service, 'registry.docker.io', 'parse auth header for Docker Hub service');
});

test('Www-Authenticate header parsing - Quay', () => {
  const parsed = parseAuthHeader(
    'Www-Authenticate: Bearer realm="https://quay.io/v2/auth",service="quay.io"'
  );
  assert.strictEqual(parsed.realm, 'https://quay.io/v2/auth', 'parse auth header for Quay realm');
  assert.strictEqual(parsed.service, 'quay.io', 'parse auth header for Quay service');
});

test('Www-Authenticate header parsing - Artifactory', () => {
  const parsed = parseAuthHeader('www-authenticate: Bearer realm="https://artifactory.corp/v2/token"');
  assert.strictEqual(parsed.realm, 'https://artifactory.corp/v2/token', 'parse auth header without service realm');
  assert.strictEqual(parsed.service, '', 'parse auth header without service');
});

test('Www-Authenticate header parsing - unquoted and upper case keys', () => {
  const parsed = parseAuthHeader(
    'WWW-AUTHENTICATE: Bearer REALM=https://example.com/token,SERVICE=example.com'
  );
  assert.strictEqual(parsed.realm, 'https://example.com/token', 'parse unquoted auth header realm');
  assert.strictEqual(parsed.service, 'example.com', 'parse unquoted auth header service');
});

test('Www-Authenticate header parsing - basic realm', () => {
  const parsed = parseAuthHeader('www-authenticate: Basic realm="foo"');
  assert.strictEqual(parsed.realm, 'foo', 'parse auth header basic realm');
});

test('Step summary rendering - HEAD and walked', () => {
  const pivotSha = 'a1b2c3d4e5f67890123456789012345678901234';
  const revision = 'HEAD';
  const candidates = [
    'a1b2c3d4e5f67890123456789012345678901234',
    'b2c3d4e5f67890123456789012345678901234a1',
    'e4f5g6h789012345678901234567890123456789'
  ];
  const pkgOrder = ['backend', 'frontend'];
  const imagePaths = {
    backend: 'bcgov/quickstart-openshift/backend',
    frontend: 'bcgov/quickstart-openshift/frontend'
  };
  const images = {
    backend: {
      sha: 'a1b2c3d4e5f67890123456789012345678901234',
      digest: 'sha256:7f83b1...',
      created: '2026-01-01T00:00:00Z',
      prNum: '10',
      msg: 'Backend commit'
    },
    frontend: {
      sha: 'e4f5g6h789012345678901234567890123456789',
      digest: 'sha256:39ac21...',
      created: '2026-01-01T00:00:00Z',
      prNum: '11',
      msg: 'Frontend commit'
    }
  };

  const output = renderStepSummary({
    registry: 'ghcr.io',
    revision,
    pivotSha,
    candidates,
    pkgOrder,
    imagePaths,
    images
  });

  const expected = [
    '### 📦 Image Tracker',
    '',
    '| Package | Target Commit | Resolved Commit | Search Depth | Image Reference / Digest |',
    '| :--- | :--- | :--- | :--- | :--- |',
    '| `backend` | `a1b2c3d` (HEAD) | `a1b2c3d` | 1 | `ghcr.io/bcgov/quickstart-openshift/backend@sha256:7f83b1...` |',
    '| `frontend` | `a1b2c3d` (HEAD) | `e4f5g6h` | 3 (walked) | `ghcr.io/bcgov/quickstart-openshift/frontend@sha256:39ac21...` |',
    ''
  ].join('\n');

  assert.strictEqual(output, expected, 'step summary matches proposed provenance audit table format');
});

test('Step summary rendering - missing and SHA revision', () => {
  const pivotSha = 'a1b2c3d4e5f67890123456789012345678901234';
  const revision = 'a1b2c3d';
  const candidates = ['a1b2c3d4e5f67890123456789012345678901234'];
  const pkgOrder = ['api', 'db'];
  const imagePaths = {
    api: 'bcgov/myapp/api',
    db: 'bcgov/myapp/db'
  };
  const images = {
    api: {
      sha: 'a1b2c3d4e5f67890123456789012345678901234',
      digest: 'sha256:111111',
      created: '2026-01-01T00:00:00Z',
      prNum: '',
      msg: 'Api commit'
    }
  };

  const output = renderStepSummary({
    registry: 'ghcr.io',
    revision,
    pivotSha,
    candidates,
    pkgOrder,
    imagePaths,
    images
  });

  const expected = [
    '### 📦 Image Tracker',
    '',
    '| Package | Target Commit | Resolved Commit | Search Depth | Image Reference / Digest |',
    '| :--- | :--- | :--- | :--- | :--- |',
    '| `api` | `a1b2c3d` | `a1b2c3d` | 1 | `ghcr.io/bcgov/myapp/api@sha256:111111` |',
    '| `db` | `a1b2c3d` | — | — | *Not resolved* |',
    ''
  ].join('\n');

  assert.strictEqual(output, expected, 'step summary handles sha revision and missing packages');
});

test('Step summary rendering - pipe escaping', () => {
  const pivotSha = 'a1b2c3d4e5f67890123456789012345678901234';
  const revision = 'feature|branch';
  const candidates = ['a1b2c3d4e5f67890123456789012345678901234'];
  const pkgOrder = ['app|service'];
  const imagePaths = {
    'app|service': 'bcgov/myapp/app_service'
  };
  const images = {
    'app|service': {
      sha: 'a1b2c3d4e5f67890123456789012345678901234',
      digest: 'sha256:222222',
      created: '2026-01-01T00:00:00Z',
      prNum: '',
      msg: 'Pipe commit'
    }
  };

  const output = renderStepSummary({
    registry: 'ghcr.io',
    revision,
    pivotSha,
    candidates,
    pkgOrder,
    imagePaths,
    images
  });

  const expected = [
    '### 📦 Image Tracker',
    '',
    '| Package | Target Commit | Resolved Commit | Search Depth | Image Reference / Digest |',
    '| :--- | :--- | :--- | :--- | :--- |',
    '| `app\\|service` | `a1b2c3d` (feature\\|branch) | `a1b2c3d` | 1 | `ghcr.io/bcgov/myapp/app_service@sha256:222222` |',
    ''
  ].join('\n');

  assert.strictEqual(output, expected, 'step summary escapes pipes in revision and package names');
});

test('Step summary rendering - custom registry host', () => {
  const registry = 'registry-1.docker.io';
  const pivotSha = 'a1b2c3d4e5f67890123456789012345678901234';
  const revision = 'HEAD';
  const candidates = ['a1b2c3d4e5f67890123456789012345678901234'];
  const pkgOrder = ['backend'];
  const imagePaths = {
    backend: 'bcgov/quickstart-openshift/backend'
  };
  const images = {
    backend: {
      sha: 'a1b2c3d4e5f67890123456789012345678901234',
      digest: 'sha256:7f83b1...',
      created: '2026-01-01T00:00:00Z',
      prNum: '10',
      msg: 'Backend commit'
    }
  };

  const output = renderStepSummary({
    registry,
    revision,
    pivotSha,
    candidates,
    pkgOrder,
    imagePaths,
    images
  });

  const expected = [
    '### 📦 Image Tracker',
    '',
    '| Package | Target Commit | Resolved Commit | Search Depth | Image Reference / Digest |',
    '| :--- | :--- | :--- | :--- | :--- |',
    '| `backend` | `a1b2c3d` (HEAD) | `a1b2c3d` | 1 | `registry-1.docker.io/bcgov/quickstart-openshift/backend@sha256:7f83b1...` |',
    ''
  ].join('\n');

  assert.strictEqual(output, expected, 'step summary uses custom registry host in image reference');
});

test('isForkPr - fork and same-repo', () => {
  const { isForkPr } = require('../index.js');
  assert.strictEqual(isForkPr('bcgov/actions', 'derekroberts/actions'), true, 'fork PR detected');
  assert.strictEqual(isForkPr('bcgov/actions', 'bcgov/actions'), false, 'same-repo PR');
  assert.strictEqual(isForkPr('bcgov/actions', ''), false, 'empty head repo');
});

test('publishRepository - matches builder-ghcr contract', () => {
  const { publishRepository } = require('../index.js');
  assert.strictEqual(
    publishRepository('pull_request', 'bcgov/foo', 'fork/foo'),
    'fork/foo',
    'fork pull_request targets head repo'
  );
  assert.strictEqual(
    publishRepository('pull_request', 'bcgov/foo', 'bcgov/foo'),
    'bcgov/foo',
    'same-repo pull_request'
  );
  assert.strictEqual(publishRepository('push', 'fork/foo', ''), 'fork/foo', 'push uses workflow repo');
});

test('resolveImageRepository - explicit override and auto fork target', () => {
  const { resolveImageRepository } = require('../index.js');
  assert.strictEqual(
    resolveImageRepository({
      inputRepository: 'bcgov/quickstart-openshift',
      ghRepository: 'bcgov/actions',
      eventName: 'pull_request',
      headRepository: 'derekroberts/actions'
    }),
    'bcgov/quickstart-openshift',
    'explicit repository overrides fork auto-resolution'
  );
  assert.strictEqual(
    resolveImageRepository({
      inputRepository: '',
      ghRepository: 'bcgov/foo',
      eventName: 'pull_request',
      headRepository: 'fork/foo'
    }),
    'fork/foo',
    'omitted input auto-targets fork GHCR on fork PR'
  );
  assert.strictEqual(
    resolveImageRepository({
      inputRepository: 'bcgov/foo',
      ghRepository: 'bcgov/foo',
      eventName: 'pull_request',
      headRepository: 'fork/foo'
    }),
    'bcgov/foo',
    'explicit workflow repo still resolves upstream images on fork PR'
  );
  assert.strictEqual(
    resolveImageRepository({
      inputRepository: '',
      ghRepository: 'fork/foo',
      eventName: 'push',
      headRepository: ''
    }),
    'fork/foo',
    'fork push uses workflow repository'
  );
});

test('imageResolveMissIsExpected - fork PR only', () => {
  const { imageResolveMissIsExpected } = require('../index.js');
  assert.strictEqual(
    imageResolveMissIsExpected('pull_request', 'bcgov/foo', 'fork/foo'),
    true,
    'fork pull_request miss is expected'
  );
  assert.strictEqual(
    imageResolveMissIsExpected('pull_request', 'bcgov/foo', 'bcgov/foo'),
    false,
    'same-repo PR miss is an error'
  );
  assert.strictEqual(imageResolveMissIsExpected('push', 'fork/foo', ''), false, 'push miss is an error');
});

const SHA = '7ba8a2cac4f6debe314be035a1ad4781bbc3df0d';

test('workflowPrFetchRef uses the workflow PR, not an API guess', () => {
  const { workflowPrFetchRef } = require('../index.js');
  assert.strictEqual(
    workflowPrFetchRef(SHA, { pull_request: { number: 379, head: { sha: SHA } } }, 'bcgov/foo', 'bcgov/foo'),
    'pull/379/head'
  );
  assert.strictEqual(
    workflowPrFetchRef(SHA, { pull_request: { number: 1, head: { sha: 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef' } } }, 'bcgov/foo', 'bcgov/foo'),
    '',
    'different head SHA is not the workflow PR'
  );
  assert.strictEqual(
    workflowPrFetchRef(SHA, { pull_request: { number: 379, head: { sha: SHA } } }, 'bcgov/other', 'bcgov/actions'),
    '',
    'external checkout does not use the workflow PR number'
  );
});

test('prLookupUrl queries the source (checkout) repository', () => {
  const { prLookupUrl } = require('../index.js');
  assert.strictEqual(
    prLookupUrl('bcgov/some-other-repo', SHA),
    `https://api.github.com/repos/bcgov/some-other-repo/commits/${SHA}/pulls`
  );
});

test('repositoryFromRemoteUrl parses origin', () => {
  const { repositoryFromRemoteUrl } = require('../index.js');
  assert.strictEqual(
    repositoryFromRemoteUrl('git@github.com:bcgov/nr-hydrometric-rating-curve.git'),
    'bcgov/nr-hydrometric-rating-curve'
  );
});

test('emptyTrackerOutputLines covers the five consumer outputs', () => {
  const { emptyTrackerOutputLines } = require('../index.js');
  const lines = emptyTrackerOutputLines();
  assert.deepStrictEqual(lines, ['images={}', 'image=', 'digest=', 'digests={}', 'pr=']);
});

test('writeEmptyGithubOutputs writes all five outputs', () => {
  const fs = require('node:fs');
  const os = require('node:os');
  const path = require('node:path');
  const { writeEmptyGithubOutputs } = require('../index.js');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tracker-out-'));
  const out = path.join(dir, 'github_output');
  writeEmptyGithubOutputs({ GITHUB_ACTIONS: 'true', GITHUB_OUTPUT: out });
  const text = fs.readFileSync(out, 'utf8');
  assert.match(text, /^images=\{\}$/m);
  assert.match(text, /^image=$/m);
  assert.match(text, /^digest=$/m);
  assert.match(text, /^digests=\{\}$/m);
  assert.match(text, /^pr=$/m);
});

test('resolvePivotSha fetches the SHA from origin before calling the API', async () => {
  const { resolvePivotSha } = require('../index.js');
  const originRefs = [];
  let apiCalled = false;
  let haveSha = false;
  const result = await resolvePivotSha({
    revision: SHA,
    token: 'token',
    sourceRepository: 'bcgov/nr-hydrometric-rating-curve',
    ghRepository: 'bcgov/nr-hydrometric-rating-curve',
    event: {},
    maxDepth: 1,
    revParse: () => (haveSha ? SHA : ''),
    fetchOrigin: (ref) => {
      originRefs.push(ref);
      if (ref === SHA) haveSha = true;
      return true;
    },
    githubFetch: async () => {
      apiCalled = true;
      return { ok: true, json: async () => [{ number: 1 }] };
    }
  });
  assert.deepStrictEqual(originRefs, [SHA]);
  assert.strictEqual(apiCalled, false, 'API must not run once origin SHA fetch succeeds');
  assert.strictEqual(result.pivotSha, SHA);
});

test('resolvePivotSha prefers workflow PR ref over API-derived PR number', async () => {
  const { resolvePivotSha } = require('../index.js');
  const originRefs = [];
  let haveSha = false;
  const result = await resolvePivotSha({
    revision: SHA,
    token: 'token',
    sourceRepository: 'bcgov/nr-hydrometric-rating-curve',
    ghRepository: 'bcgov/nr-hydrometric-rating-curve',
    event: {
      pull_request: { number: 379, title: 'playwright', head: { sha: SHA } }
    },
    maxDepth: 1,
    revParse: () => (haveSha ? SHA : ''),
    fetchOrigin: (ref) => {
      originRefs.push(ref);
      if (ref === 'pull/379/head') haveSha = true;
      return true;
    },
    githubFetch: async () => {
      throw new Error('API should not run when workflow PR fetch succeeds');
    }
  });
  assert.deepStrictEqual(originRefs, [SHA, 'pull/379/head']);
  assert.strictEqual(result.pivotSha, SHA);
});

test('resolvePivotSha API fallback uses source repository, not workflow or image repo', async () => {
  const { resolvePivotSha } = require('../index.js');
  const urls = [];
  let haveSha = false;
  await resolvePivotSha({
    revision: SHA,
    token: 'token',
    sourceRepository: 'bcgov/some-other-repo',
    ghRepository: 'bcgov/actions',
    event: {
      pull_request: { number: 99, head: { sha: SHA } }
    },
    maxDepth: 1,
    revParse: () => (haveSha ? SHA : ''),
    fetchOrigin: (ref) => {
      if (ref === 'pull/12/head') haveSha = true;
      return true;
    },
    githubFetch: async (url) => {
      urls.push(url);
      return {
        ok: true,
        json: async () => [{ number: 12, title: 'x', head: { sha: SHA } }]
      };
    }
  });
  assert.equal(urls.length, 1);
  assert.ok(urls[0].includes('repos/bcgov/some-other-repo/commits/'));
  assert.ok(!urls[0].includes('bcgov/actions'));
});

const ENV_KEYS = [
  'GITHUB_ACTIONS',
  'GITHUB_OUTPUT',
  'GITHUB_EVENT_PATH',
  'GITHUB_REPOSITORY',
  'GITHUB_EVENT_NAME',
  'INPUT_PACKAGE',
  'PACKAGE',
  'INPUT_REPOSITORY',
  'REPOSITORY',
  'INPUT_REVISION',
  'REVISION',
  'DIR',
  'INPUT_DIR',
  'GITHUB_TOKEN',
  'INPUT_GITHUB_TOKEN',
  'TOKEN'
];

function snapshotEnv() {
  const saved = {};
  for (const k of ENV_KEYS) saved[k] = process.env[k];
  return saved;
}

function restoreEnv(saved) {
  for (const [k, v] of Object.entries(saved)) {
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
}

async function withTempGitOrigin(originUrl, fn) {
  const fs = require('node:fs');
  const os = require('node:os');
  const path = require('node:path');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tracker-git-'));
  execFileSync('git', ['init'], { cwd: dir, stdio: 'ignore' });
  execFileSync('git', ['remote', 'add', 'origin', originUrl], { cwd: dir, stdio: 'ignore' });
  const cwd = process.cwd();
  try {
    return await fn(dir);
  } finally {
    process.chdir(cwd);
  }
}

test('runMain fork unresolvable revision exits 0 with empty outputs', async () => {
  const fs = require('node:fs');
  const os = require('node:os');
  const path = require('node:path');
  const { runMain } = require('../index.js');
  const saved = snapshotEnv();
  const cwd = process.cwd();
  await withTempGitOrigin('file:///nonexistent-image-tracker-origin.git', async (dir) => {
    const out = path.join(dir, 'github_output');
    const eventPath = path.join(dir, 'event.json');
    fs.writeFileSync(
      eventPath,
      JSON.stringify({
        pull_request: { number: 379, head: { sha: SHA, repo: { full_name: 'fork/foo' } } }
      })
    );
    process.env.GITHUB_ACTIONS = 'true';
    process.env.GITHUB_OUTPUT = out;
    process.env.GITHUB_EVENT_PATH = eventPath;
    process.env.GITHUB_REPOSITORY = 'bcgov/foo';
    process.env.GITHUB_EVENT_NAME = 'pull_request';
    process.env.INPUT_PACKAGE = 'frontend';
    process.env.PACKAGE = 'frontend';
    process.env.INPUT_REPOSITORY = 'fork/foo';
    process.env.REPOSITORY = 'fork/foo';
    process.env.INPUT_REVISION = SHA;
    process.env.REVISION = SHA;
    process.env.DIR = dir;
    process.env.INPUT_DIR = dir;
    delete process.env.GITHUB_TOKEN;
    delete process.env.INPUT_GITHUB_TOKEN;
    delete process.env.TOKEN;
    await runMain();
    const text = fs.readFileSync(out, 'utf8');
    assert.match(text, /^images=\{\}$/m);
    assert.match(text, /^image=$/m);
    assert.match(text, /^digest=$/m);
    assert.match(text, /^digests=\{\}$/m);
    assert.match(text, /^pr=$/m);
  });
  process.chdir(cwd);
  restoreEnv(saved);
});

test('runMain same-repo unresolvable revision still exits 1', async () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const { runMain } = require('../index.js');
  const saved = snapshotEnv();
  const cwd = process.cwd();
  const origExit = process.exit;
  let exitCode;
  process.exit = (code) => {
    exitCode = code;
    throw new Error('__exit__');
  };
  try {
    await withTempGitOrigin('file:///nonexistent-image-tracker-origin.git', async (dir) => {
      const eventPath = path.join(dir, 'event.json');
      fs.writeFileSync(
        eventPath,
        JSON.stringify({
          pull_request: { number: 10, head: { sha: SHA, repo: { full_name: 'bcgov/foo' } } }
        })
      );
      process.env.GITHUB_ACTIONS = 'true';
      process.env.GITHUB_OUTPUT = path.join(dir, 'github_output');
      process.env.GITHUB_EVENT_PATH = eventPath;
      process.env.GITHUB_REPOSITORY = 'bcgov/foo';
      process.env.GITHUB_EVENT_NAME = 'pull_request';
      process.env.INPUT_PACKAGE = 'frontend';
      process.env.PACKAGE = 'frontend';
      process.env.INPUT_REVISION = SHA;
      process.env.REVISION = SHA;
      process.env.DIR = dir;
      process.env.INPUT_DIR = dir;
      delete process.env.INPUT_REPOSITORY;
      delete process.env.REPOSITORY;
      delete process.env.GITHUB_TOKEN;
      delete process.env.INPUT_GITHUB_TOKEN;
      delete process.env.TOKEN;
      await assert.rejects(() => runMain(), /__exit__/);
      assert.strictEqual(exitCode, 1);
    });
  } finally {
    process.exit = origExit;
    process.chdir(cwd);
    restoreEnv(saved);
  }
});

test('probeTag returns hit when revision annotation matches candidate tag (short and full SHA)', async () => {
  const { probeTag } = require('../index.js');
  const origFetch = global.fetch;
  const sha = 'e261c9651c7df0e104e79124443fa48a0446411f';

  for (const tag of [`sha-${sha.slice(0, 7)}`, sha]) {
    const expectedDigest = `sha256:${tag.padEnd(64, '0')}`;
    global.fetch = async (url) => {
      if (url.includes(`/manifests/${tag}`)) {
        return {
          ok: true,
          headers: {
            get: (h) => (h.toLowerCase() === 'docker-content-digest' ? expectedDigest : null)
          },
          json: async () => ({
            mediaType: 'application/vnd.oci.image.manifest.v1+json',
            digest: expectedDigest,
            annotations: {
              'org.opencontainers.image.revision': sha,
              'org.opencontainers.image.created': '2026-09-05T00:00:00Z'
            }
          })
        };
      }
      return { ok: false };
    };

    try {
      const res = await probeTag(
        'bcgov/quickstart-openshift/frontend',
        tag,
        'fake-bearer',
        'ghcr.io',
        [sha],
        {},
        {},
        {},
        {},
        false
      );
      assert.ok(res, `probeTag should return hit for ${tag}`);
      assert.strictEqual(res.sha, sha);
      assert.strictEqual(res.digest, expectedDigest);
    } finally {
      global.fetch = origFetch;
    }
  }
});

test('probeTag and matchesCandidate reject mutable PR tag when revision is unrelated or absent', async () => {
  const { probeTag, matchesCandidate } = require('../index.js');
  const origFetch = global.fetch;
  const sha = 'e261c9651c7df0e104e79124443fa48a0446411f';
  const prNumMap = { [sha]: '99' };

  // matchesCandidate rejects PR tag if revision is given but does not match
  assert.strictEqual(
    matchesCandidate('deadbeefdeadbeefdeadbeefdeadbeefdeadbeef', 'pr-99', [sha], {}, prNumMap),
    false,
    'matchesCandidate rejects PR tag when revision is unrelated'
  );

  const mockProbeWithRevision = async (revision) => {
    global.fetch = async () => ({
      ok: true,
      headers: { get: () => 'sha256:1111111111111111111111111111111111111111111111111111111111111111' },
      json: async () => ({
        mediaType: 'application/vnd.oci.image.manifest.v1+json',
        digest: 'sha256:1111111111111111111111111111111111111111111111111111111111111111',
        annotations: revision ? { 'org.opencontainers.image.revision': revision } : {}
      })
    });
    try {
      return await probeTag('bcgov/quickstart/frontend', 'pr-99', 'b', 'ghcr.io', [sha], {}, prNumMap, {}, {}, false);
    } finally {
      global.fetch = origFetch;
    }
  };

  assert.strictEqual(await mockProbeWithRevision('deadbeef'), null, 'probeTag rejects PR tag with unrelated revision');
  assert.strictEqual(await mockProbeWithRevision(''), null, 'probeTag rejects PR tag with absent revision');
  const validHit = await mockProbeWithRevision(sha);
  assert.ok(validHit, 'probeTag accepts PR tag when revision matches candidate');
  assert.strictEqual(validHit.sha, sha);
});



