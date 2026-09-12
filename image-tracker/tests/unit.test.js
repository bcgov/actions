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

test('pivot PR helpers reject a different PR hit and allow unmapped walk', () => {
  const { pivotPrNumber, isStaleAncestorHit, isForeignPrCandidate } = require('../index.js');
  assert.strictEqual(pivotPrNumber('aaa', { aaa: '379' }), '379');
  assert.strictEqual(pivotPrNumber('aaa', {}), '');
  assert.strictEqual(isStaleAncestorHit({ prNum: '383' }, '379'), true);
  assert.strictEqual(isStaleAncestorHit({ prNum: '379' }, '379'), false);
  assert.strictEqual(isStaleAncestorHit({ prNum: '' }, '379'), false);
  assert.strictEqual(isStaleAncestorHit({ prNum: '383' }, ''), false);
  assert.strictEqual(isForeignPrCandidate('bbb', { bbb: '383' }, '379'), true);
  assert.strictEqual(isForeignPrCandidate('aaa', { aaa: '379' }, '379'), false);
  assert.strictEqual(isForeignPrCandidate('ccc', {}, '379'), false);
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

test('publishRepository - matches builder contract', () => {
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

test('runMain fork unresolvable revision exits 1', async () => {
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
          pull_request: { number: 379, head: { sha: SHA, repo: { full_name: 'fork/foo' } } }
        })
      );
      process.env.GITHUB_ACTIONS = 'true';
      process.env.GITHUB_OUTPUT = path.join(dir, 'github_output');
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
      delete process.env.GH_TOKEN;
      delete process.env.INPUT_GITHUB_TOKEN;
      delete process.env.TOKEN;
      delete process.env.INPUT_TOKEN;
      await assert.rejects(() => runMain(), /__exit__/);
      assert.strictEqual(exitCode, 1);
    });
  } finally {
    process.exit = origExit;
    process.chdir(cwd);
    restoreEnv(saved);
  }
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

test('repositoryFromRemoteUrl parses origin and retains dots while stripping terminal .git', () => {
  const { repositoryFromRemoteUrl } = require('../index.js');
  assert.strictEqual(
    repositoryFromRemoteUrl('git@github.com:bcgov/nr-hydrometric-rating-curve.git'),
    'bcgov/nr-hydrometric-rating-curve'
  );
  assert.strictEqual(
    repositoryFromRemoteUrl('https://github.com/owner/app.one.git'),
    'owner/app.one'
  );
  assert.strictEqual(
    repositoryFromRemoteUrl('https://github.com/owner/app.one'),
    'owner/app.one'
  );
  assert.strictEqual(
    repositoryFromRemoteUrl('https://github.com/owner/app.two.git'),
    'owner/app.two'
  );
  assert.notStrictEqual(
    repositoryFromRemoteUrl('https://github.com/owner/app.one.git'),
    repositoryFromRemoteUrl('https://github.com/owner/app.two.git')
  );
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
  'GITHUB_REF',
  'GITHUB_SHA',
  'INPUT_PACKAGE',
  'PACKAGE',
  'INPUT_REPOSITORY',
  'REPOSITORY',
  'INPUT_REVISION',
  'REVISION',
  'DIR',
  'INPUT_DIR',
  'GITHUB_TOKEN',
  'GH_TOKEN',
  'INPUT_GITHUB_TOKEN',
  'TOKEN',
  'INPUT_TOKEN'
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
      delete process.env.GH_TOKEN;
      delete process.env.INPUT_GITHUB_TOKEN;
      delete process.env.TOKEN;
      delete process.env.INPUT_TOKEN;
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

test('isShallowRepository and gitFetchDeepen auto-deepen shallow clones (Issue #41)', () => {
  const fs = require('node:fs');
  const os = require('node:os');
  const path = require('node:path');
  const { isShallowRepository, gitFetchDeepen } = require('../index.js');

  const baseDir = fs.mkdtempSync(path.join(os.tmpdir(), 'base-repo-'));
  const shallowDir = fs.mkdtempSync(path.join(os.tmpdir(), 'shallow-repo-'));
  const cwd = process.cwd();

  try {
    execFileSync('git', ['init', '-b', 'main'], { cwd: baseDir, stdio: 'ignore' });
    execFileSync('git', ['config', 'user.name', 'Test'], { cwd: baseDir, stdio: 'ignore' });
    execFileSync('git', ['config', 'user.email', 'test@example.com'], { cwd: baseDir, stdio: 'ignore' });
    for (let i = 1; i <= 3; i++) {
      fs.writeFileSync(path.join(baseDir, `file${i}.txt`), `commit ${i}\n`);
      execFileSync('git', ['add', '.'], { cwd: baseDir, stdio: 'ignore' });
      execFileSync('git', ['commit', '-m', `commit ${i}`], { cwd: baseDir, stdio: 'ignore' });
    }

    execFileSync('git', ['clone', '--depth', '1', `file://${baseDir}`, shallowDir], { stdio: 'ignore' });

    process.chdir(shallowDir);
    assert.strictEqual(isShallowRepository(), true, 'shallow clone is identified as shallow');

    const initialCommits = execFileSync('git', ['rev-list', '--count', 'HEAD'], { encoding: 'utf8' }).trim();
    assert.strictEqual(initialCommits, '1', 'initial shallow count is 1');

    const pivotSha = execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
    const deepened = gitFetchDeepen(pivotSha, 3);
    assert.strictEqual(deepened, true, 'gitFetchDeepen returns true');

    const deepenedCommits = execFileSync('git', ['rev-list', '--count', 'HEAD'], { encoding: 'utf8' }).trim();
    assert.strictEqual(deepenedCommits, '3', 'deepened count includes all 3 commits');
  } finally {
    process.chdir(cwd);
    fs.rmSync(baseDir, { recursive: true, force: true });
    fs.rmSync(shallowDir, { recursive: true, force: true });
  }
});

test('gitFetchDeepen deepens history from pivotSha on detached / non-default shallow checkout', () => {
  const fs = require('node:fs');
  const os = require('node:os');
  const path = require('node:path');
  const { isShallowRepository, gitFetchDeepen } = require('../index.js');

  const baseDir = fs.mkdtempSync(path.join(os.tmpdir(), 'base-repo-'));
  const shallowDir = fs.mkdtempSync(path.join(os.tmpdir(), 'shallow-repo-'));
  const cwd = process.cwd();

  try {
    execFileSync('git', ['init', '-b', 'main'], { cwd: baseDir, stdio: 'ignore' });
    execFileSync('git', ['config', 'user.name', 'Test'], { cwd: baseDir, stdio: 'ignore' });
    execFileSync('git', ['config', 'user.email', 'test@example.com'], { cwd: baseDir, stdio: 'ignore' });
    fs.writeFileSync(path.join(baseDir, 'main.txt'), 'main 1\n');
    execFileSync('git', ['add', '.'], { cwd: baseDir, stdio: 'ignore' });
    execFileSync('git', ['commit', '-m', 'main commit'], { cwd: baseDir, stdio: 'ignore' });

    execFileSync('git', ['checkout', '-b', 'feature'], { cwd: baseDir, stdio: 'ignore' });
    for (let i = 1; i <= 3; i++) {
      fs.writeFileSync(path.join(baseDir, `feature${i}.txt`), `feat ${i}\n`);
      execFileSync('git', ['add', '.'], { cwd: baseDir, stdio: 'ignore' });
      execFileSync('git', ['commit', '-m', `feature ${i}`], { cwd: baseDir, stdio: 'ignore' });
    }
    const featureHead = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: baseDir, encoding: 'utf8' }).trim();

    execFileSync('git', ['checkout', 'main'], { cwd: baseDir, stdio: 'ignore' });

    execFileSync('git', ['clone', '--depth', '1', '--branch', 'feature', `file://${baseDir}`, shallowDir], {
      stdio: 'ignore'
    });
    execFileSync('git', ['checkout', '--detach'], { cwd: shallowDir, stdio: 'ignore' });

    process.chdir(shallowDir);
    assert.strictEqual(isShallowRepository(), true, 'shallow clone is identified as shallow');

    const initialCommits = execFileSync('git', ['rev-list', '--count', 'HEAD'], { encoding: 'utf8' }).trim();
    assert.strictEqual(initialCommits, '1', 'initial shallow count is 1 on detached feature');

    const deepened = gitFetchDeepen(featureHead, 4);
    assert.strictEqual(deepened, true, 'gitFetchDeepen returns true');

    const deepenedCommits = execFileSync('git', ['rev-list', '--count', 'HEAD'], { encoding: 'utf8' }).trim();
    assert.strictEqual(deepenedCommits, '4', 'deepened count includes all feature and main ancestors');
  } finally {
    process.chdir(cwd);
    fs.rmSync(baseDir, { recursive: true, force: true });
    fs.rmSync(shallowDir, { recursive: true, force: true });
  }
});

test('probeTag and matchesCandidate accept PR merge commit revision for PR and head SHA tags', async () => {
  const { probeTag, matchesCandidate } = require('../index.js');
  const origFetch = global.fetch;

  const headSha = '637f189b2e0aed0a8d0b4af224f62af1ffd1bd50';
  const mergeSha = '64a5a332364b27b8998f1af66926cda2cc667ddd';
  const prNum = '383';

  const candidates = [headSha];
  const prMap = { [headSha]: headSha };
  const prNumMap = { [headSha]: prNum };
  const prMergeMap = { [headSha]: mergeSha };

  // matchesCandidate verifies mergeSha against revision
  assert.strictEqual(
    matchesCandidate(mergeSha, 'pr-383', candidates, prMap, prNumMap, prMergeMap),
    true,
    'matchesCandidate accepts pr-383 when revision is mergeSha'
  );
  assert.strictEqual(
    matchesCandidate(mergeSha, '383', candidates, prMap, prNumMap, prMergeMap),
    true,
    'matchesCandidate accepts 383 when revision is mergeSha'
  );
  assert.strictEqual(
    matchesCandidate(mergeSha, headSha, candidates, prMap, prNumMap, prMergeMap),
    true,
    'matchesCandidate accepts headSha tag when revision is mergeSha'
  );
  assert.strictEqual(
    matchesCandidate(mergeSha, `sha-${mergeSha.slice(0, 7)}`, candidates, prMap, prNumMap, prMergeMap),
    true,
    'matchesCandidate accepts short merge sha tag when revision is mergeSha'
  );
  assert.strictEqual(
    matchesCandidate('deadbeefdeadbeefdeadbeefdeadbeefdeadbeef', 'pr-383', candidates, prMap, prNumMap, prMergeMap),
    false,
    'matchesCandidate rejects unrelated revision even with prMergeMap'
  );

  // probeTag mock returning mergeSha in revision label
  const testTags = ['pr-383', '383', headSha, `sha-${mergeSha.slice(0, 7)}`];
  for (const tag of testTags) {
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
              'org.opencontainers.image.revision': mergeSha,
              'org.opencontainers.image.created': '2026-09-07T10:16:57Z'
            }
          })
        };
      }
      return { ok: false };
    };

    try {
      const res = await probeTag(
        'bcgov/nr-hydrometric-rating-curve/frontend',
        tag,
        'fake-bearer',
        'ghcr.io',
        candidates,
        prMap,
        prNumMap,
        {},
        {},
        false,
        prMergeMap
      );
      assert.ok(res, `probeTag should return hit for tag ${tag} when revision is mergeSha`);
      assert.strictEqual(res.sha, headSha);
      assert.strictEqual(res.digest, expectedDigest);
    } finally {
      global.fetch = origFetch;
    }
  }
});

test('runMain resolves PR image when git HEAD is a synthetic merge commit', async () => {
  const fs = require('node:fs');
  const os = require('node:os');
  const path = require('node:path');
  const { runMain } = require('../index.js');
  const origFetch = global.fetch;
  const origExit = process.exit;
  const saved = snapshotEnv();
  const cwd = process.cwd();

  const repoDir = fs.mkdtempSync(path.join(os.tmpdir(), 'git-merge-test-'));

  try {
    process.exit = (code) => {
      throw new Error(`process.exit called with code ${code}`);
    };

    // Set up git repo with a merge commit having 2 parents: main and PR branch
    execFileSync('git', ['init', '-b', 'main'], { cwd: repoDir, stdio: 'ignore' });
    execFileSync('git', ['config', 'user.name', 'Test'], { cwd: repoDir, stdio: 'ignore' });
    execFileSync('git', ['config', 'user.email', 'test@example.com'], { cwd: repoDir, stdio: 'ignore' });

    fs.writeFileSync(path.join(repoDir, 'base.txt'), 'base\n');
    execFileSync('git', ['add', '.'], { cwd: repoDir, stdio: 'ignore' });
    execFileSync('git', ['commit', '-m', 'initial commit'], { cwd: repoDir, stdio: 'ignore' });

    execFileSync('git', ['checkout', '-b', 'pr-branch'], { cwd: repoDir, stdio: 'ignore' });
    fs.writeFileSync(path.join(repoDir, 'pr.txt'), 'pr feature\n');
    execFileSync('git', ['add', '.'], { cwd: repoDir, stdio: 'ignore' });
    execFileSync('git', ['commit', '-m', 'pr feature commit'], { cwd: repoDir, stdio: 'ignore' });
    const headSha = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: repoDir, encoding: 'utf8' }).trim();

    execFileSync('git', ['checkout', 'main'], { cwd: repoDir, stdio: 'ignore' });
    fs.writeFileSync(path.join(repoDir, 'main.txt'), 'main advance\n');
    execFileSync('git', ['add', '.'], { cwd: repoDir, stdio: 'ignore' });
    execFileSync('git', ['commit', '-m', 'main advance'], { cwd: repoDir, stdio: 'ignore' });

    execFileSync('git', ['merge', '--no-ff', 'pr-branch', '-m', 'Merge pr-branch into main'], {
      cwd: repoDir,
      stdio: 'ignore'
    });
    const mergeSha = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: repoDir, encoding: 'utf8' }).trim();

    const expectedDigest = 'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    const calls = [];
    global.fetch = async (url) => {
      calls.push(url);
      if (url.endsWith('/manifests/latest')) {
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
      if (url.includes('/token?')) {
        return {
          ok: true,
          status: 200,
          headers: { get: () => null },
          json: async () => ({ token: 'mock-token' })
        };
      }
      if (url.includes('/manifests/')) {
        if (url.includes(`/manifests/${headSha}`) || url.includes(`/manifests/sha-${mergeSha.slice(0, 7)}`)) {
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
                'org.opencontainers.image.revision': mergeSha,
                'org.opencontainers.image.created': '2026-09-07T10:16:57Z'
              }
            })
          };
        }
      }
      return {
        ok: false,
        status: 404,
        headers: { get: () => null },
        json: async () => ({})
      };
    };

    const eventPath = path.join(repoDir, 'event.json');
    fs.writeFileSync(
      eventPath,
      JSON.stringify({
        pull_request: {
          number: 383,
          head: { sha: headSha },
          title: 'pr feature commit'
        }
      })
    );

    const out = path.join(repoDir, 'github_output');
    process.env.GITHUB_ACTIONS = 'true';
    process.env.GITHUB_OUTPUT = out;
    process.env.GITHUB_EVENT_PATH = eventPath;
    process.env.GITHUB_EVENT_NAME = 'pull_request';
    process.env.GITHUB_REF = 'refs/pull/383/merge';
    process.env.INPUT_PACKAGE = 'frontend';
    process.env.PACKAGE = 'frontend';
    process.env.INPUT_REPOSITORY = 'bcgov/nr-hydrometric-rating-curve';
    process.env.REPOSITORY = 'bcgov/nr-hydrometric-rating-curve';
    process.env.INPUT_REVISION = headSha;
    process.env.REVISION = headSha;
    process.env.DIR = repoDir;
    process.env.INPUT_DIR = repoDir;
    delete process.env.GITHUB_TOKEN;
    delete process.env.INPUT_TOKEN;
    delete process.env.TOKEN;

    await runMain();

    const text = fs.readFileSync(out, 'utf8');
    assert.match(
      text,
      new RegExp(`^image=ghcr\\.io/bcgov/nr-hydrometric-rating-curve/frontend@${expectedDigest}$`, 'm'),
      'runMain outputs correct image ref'
    );
    assert.match(text, new RegExp(`^digest=${expectedDigest}$`, 'm'), 'runMain outputs correct digest');
    assert.ok(
      !calls.some((c) => c.includes('/tags/list') || c.includes('/packages/container/')),
      'runMain resolved via direct probe without iterative scan'
    );
  } finally {
    global.fetch = origFetch;
    process.exit = origExit;
    process.chdir(cwd);
    restoreEnv(saved);
    fs.rmSync(repoDir, { recursive: true, force: true });
  }
});

test('runMain resolves PR image using GITHUB_EVENT_PATH merge_commit_sha without token', async () => {
  const fs = require('node:fs');
  const os = require('node:os');
  const path = require('node:path');
  const { runMain } = require('../index.js');
  const origFetch = global.fetch;
  const origExit = process.exit;
  const saved = snapshotEnv();
  const cwd = process.cwd();

  const repoDir = fs.mkdtempSync(path.join(os.tmpdir(), 'git-event-test-'));
  const mergeSha = '64a5a332364b27b8998f1af66926cda2cc667ddd';

  try {
    process.exit = (code) => {
      throw new Error(`process.exit called with code ${code}`);
    };

    execFileSync('git', ['init', '-b', 'main'], { cwd: repoDir, stdio: 'ignore' });
    execFileSync('git', ['config', 'user.name', 'Test'], { cwd: repoDir, stdio: 'ignore' });
    execFileSync('git', ['config', 'user.email', 'test@example.com'], { cwd: repoDir, stdio: 'ignore' });
    fs.writeFileSync(path.join(repoDir, 'file.txt'), 'content\n');
    execFileSync('git', ['add', '.'], { cwd: repoDir, stdio: 'ignore' });
    execFileSync('git', ['commit', '-m', 'initial commit'], { cwd: repoDir, stdio: 'ignore' });
    const headSha = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: repoDir, encoding: 'utf8' }).trim();

    const eventPath = path.join(repoDir, 'event.json');
    fs.writeFileSync(
      eventPath,
      JSON.stringify({
        pull_request: {
          number: 383,
          head: { sha: headSha },
          merge_commit_sha: mergeSha,
          title: 'chore(deps): lock file maintenance'
        }
      })
    );

    const expectedDigest = 'sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
    const calls = [];
    global.fetch = async (url) => {
      calls.push(url);
      if (url.endsWith('/manifests/latest')) {
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
      if (url.includes('/token?')) {
        return {
          ok: true,
          status: 200,
          headers: { get: () => null },
          json: async () => ({ token: 'mock-token' })
        };
      }
      if (url.includes('/manifests/')) {
        if (url.includes('/manifests/pr-383') || url.includes('/manifests/383')) {
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
                'org.opencontainers.image.revision': mergeSha,
                'org.opencontainers.image.created': '2026-09-07T10:16:57Z'
              }
            })
          };
        }
      }
      return {
        ok: false,
        status: 404,
        headers: { get: () => null },
        json: async () => ({})
      };
    };

    const out = path.join(repoDir, 'github_output');
    process.env.GITHUB_ACTIONS = 'true';
    process.env.GITHUB_OUTPUT = out;
    process.env.GITHUB_EVENT_PATH = eventPath;
    process.env.GITHUB_EVENT_NAME = 'pull_request';
    process.env.INPUT_PACKAGE = 'frontend';
    process.env.PACKAGE = 'frontend';
    process.env.INPUT_REPOSITORY = 'bcgov/nr-hydrometric-rating-curve';
    process.env.REPOSITORY = 'bcgov/nr-hydrometric-rating-curve';
    process.env.INPUT_REVISION = headSha;
    process.env.REVISION = headSha;
    process.env.DIR = repoDir;
    process.env.INPUT_DIR = repoDir;
    delete process.env.GITHUB_TOKEN;
    delete process.env.INPUT_TOKEN;
    delete process.env.TOKEN;

    await runMain();

    const text = fs.readFileSync(out, 'utf8');
    assert.match(text, new RegExp(`^digest=${expectedDigest}$`, 'm'), 'runMain outputs resolved digest');
    assert.match(text, /^pr=383$/m, 'runMain outputs resolved PR number');
    assert.ok(
      !calls.some((c) => c.includes('/tags/list') || c.includes('/packages/container/')),
      'runMain resolved via direct candidate probe'
    );
  } finally {
    global.fetch = origFetch;
    process.exit = origExit;
    process.chdir(cwd);
    restoreEnv(saved);
    fs.rmSync(repoDir, { recursive: true, force: true });
  }
});

test('runMain rejects two-parent merge commit on push event to prevent non-PR ancestry leaks', async () => {
  const fs = require('node:fs');
  const os = require('node:os');
  const path = require('node:path');
  const { runMain } = require('../index.js');
  const origFetch = global.fetch;
  const origExit = process.exit;
  const saved = snapshotEnv();
  const cwd = process.cwd();

  const repoDir = fs.mkdtempSync(path.join(os.tmpdir(), 'git-merge-push-test-'));

  try {
    process.exit = (code) => {
      throw new Error(`process.exit called with code ${code}`);
    };

    // Set up git repo with a merge commit having 2 parents: main and feature branch
    execFileSync('git', ['init', '-b', 'main'], { cwd: repoDir, stdio: 'ignore' });
    execFileSync('git', ['config', 'user.name', 'Test'], { cwd: repoDir, stdio: 'ignore' });
    execFileSync('git', ['config', 'user.email', 'test@example.com'], { cwd: repoDir, stdio: 'ignore' });

    fs.writeFileSync(path.join(repoDir, 'base.txt'), 'base\n');
    execFileSync('git', ['add', '.'], { cwd: repoDir, stdio: 'ignore' });
    execFileSync('git', ['commit', '-m', 'initial commit'], { cwd: repoDir, stdio: 'ignore' });

    execFileSync('git', ['checkout', '-b', 'feature'], { cwd: repoDir, stdio: 'ignore' });
    fs.writeFileSync(path.join(repoDir, 'feat.txt'), 'feature\n');
    execFileSync('git', ['add', '.'], { cwd: repoDir, stdio: 'ignore' });
    execFileSync('git', ['commit', '-m', 'feature commit'], { cwd: repoDir, stdio: 'ignore' });
    const headSha = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: repoDir, encoding: 'utf8' }).trim();

    execFileSync('git', ['checkout', 'main'], { cwd: repoDir, stdio: 'ignore' });
    fs.writeFileSync(path.join(repoDir, 'main.txt'), 'main advance\n');
    execFileSync('git', ['add', '.'], { cwd: repoDir, stdio: 'ignore' });
    execFileSync('git', ['commit', '-m', 'main advance'], { cwd: repoDir, stdio: 'ignore' });

    execFileSync('git', ['merge', '--no-ff', 'feature', '-m', 'Merge feature into main'], {
      cwd: repoDir,
      stdio: 'ignore'
    });
    const mergeSha = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: repoDir, encoding: 'utf8' }).trim();

    global.fetch = async (url) => {
      if (url.endsWith('/manifests/latest')) {
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
      if (url.includes('/token?')) {
        return {
          ok: true,
          status: 200,
          headers: { get: () => null },
          json: async () => ({ token: 'mock-token' })
        };
      }
      // Image was labeled with mergeSha (descendant HEAD), not feature headSha
      if (url.includes('/manifests/')) {
        if (url.includes(`/manifests/${headSha}`) || url.includes(`/manifests/sha-${mergeSha.slice(0, 7)}`)) {
          return {
            ok: true,
            status: 200,
            headers: {
              get: (h) => (h.toLowerCase() === 'docker-content-digest' ? 'sha256:1111' : null)
            },
            json: async () => ({
              mediaType: 'application/vnd.oci.image.manifest.v1+json',
              digest: 'sha256:1111',
              annotations: {
                'org.opencontainers.image.revision': mergeSha
              }
            })
          };
        }
      }
      return {
        ok: false,
        status: 404,
        headers: { get: () => null },
        json: async () => ({})
      };
    };

    const out = path.join(repoDir, 'github_output');
    process.env.GITHUB_ACTIONS = 'true';
    process.env.GITHUB_OUTPUT = out;
    process.env.GITHUB_EVENT_NAME = 'push';
    process.env.GITHUB_REF = 'refs/heads/main';
    process.env.INPUT_PACKAGE = 'frontend';
    process.env.PACKAGE = 'frontend';
    process.env.INPUT_REPOSITORY = 'bcgov/nr-hydrometric-rating-curve';
    process.env.REPOSITORY = 'bcgov/nr-hydrometric-rating-curve';
    process.env.INPUT_REVISION = headSha;
    process.env.REVISION = headSha;
    process.env.DIR = repoDir;
    process.env.INPUT_DIR = repoDir;
    delete process.env.GITHUB_TOKEN;
    delete process.env.INPUT_TOKEN;
    delete process.env.TOKEN;
    delete process.env.GITHUB_EVENT_PATH;

    // Must reject because on push, two-parent HEAD is not a synthetic PR merge
    await assert.rejects(() => runMain(), /process\.exit called with code 1/);
  } finally {
    global.fetch = origFetch;
    process.exit = origExit;
    process.chdir(cwd);
    restoreEnv(saved);
    fs.rmSync(repoDir, { recursive: true, force: true });
  }
});

test('runMain ignores GITHUB_SHA fallback when GITHUB_REF is not synthetic merge ref (e.g. pull_request_target)', async () => {
  const fs = require('node:fs');
  const os = require('node:os');
  const path = require('node:path');
  const { runMain } = require('../index.js');
  const origFetch = global.fetch;
  const origExit = process.exit;
  const saved = snapshotEnv();
  const cwd = process.cwd();

  const repoDir = fs.mkdtempSync(path.join(os.tmpdir(), 'git-pr-target-test-'));
  const baseSha = '1111111111111111111111111111111111111111';

  try {
    process.exit = (code) => {
      throw new Error(`process.exit called with code ${code}`);
    };

    execFileSync('git', ['init', '-b', 'main'], { cwd: repoDir, stdio: 'ignore' });
    execFileSync('git', ['config', 'user.name', 'Test'], { cwd: repoDir, stdio: 'ignore' });
    execFileSync('git', ['config', 'user.email', 'test@example.com'], { cwd: repoDir, stdio: 'ignore' });
    fs.writeFileSync(path.join(repoDir, 'file.txt'), 'content\n');
    execFileSync('git', ['add', '.'], { cwd: repoDir, stdio: 'ignore' });
    execFileSync('git', ['commit', '-m', 'initial commit'], { cwd: repoDir, stdio: 'ignore' });
    const headSha = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: repoDir, encoding: 'utf8' }).trim();

    const eventPath = path.join(repoDir, 'event.json');
    fs.writeFileSync(
      eventPath,
      JSON.stringify({
        pull_request: {
          number: 383,
          head: { sha: headSha },
          title: 'test pr'
          // Notice: no merge_commit_sha!
        }
      })
    );

    global.fetch = async (url) => {
      if (url.endsWith('/manifests/latest')) {
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
      if (url.includes('/token?')) {
        return {
          ok: true,
          status: 200,
          headers: { get: () => null },
          json: async () => ({ token: 'mock-token' })
        };
      }
      // Image was built from base-branch SHA (GITHUB_SHA in pull_request_target)
      if (url.includes('/manifests/')) {
        if (url.includes('/manifests/pr-383') || url.includes('/manifests/383')) {
          return {
            ok: true,
            status: 200,
            headers: {
              get: (h) => (h.toLowerCase() === 'docker-content-digest' ? 'sha256:2222' : null)
            },
            json: async () => ({
              mediaType: 'application/vnd.oci.image.manifest.v1+json',
              digest: 'sha256:2222',
              annotations: {
                'org.opencontainers.image.revision': baseSha
              }
            })
          };
        }
      }
      return {
        ok: false,
        status: 404,
        headers: { get: () => null },
        json: async () => ({})
      };
    };

    const out = path.join(repoDir, 'github_output');
    process.env.GITHUB_ACTIONS = 'true';
    process.env.GITHUB_OUTPUT = out;
    process.env.GITHUB_EVENT_PATH = eventPath;
    process.env.GITHUB_EVENT_NAME = 'pull_request_target';
    process.env.GITHUB_REF = 'refs/heads/main'; // base branch ref
    process.env.GITHUB_SHA = baseSha; // base branch commit
    process.env.INPUT_PACKAGE = 'frontend';
    process.env.PACKAGE = 'frontend';
    process.env.INPUT_REPOSITORY = 'bcgov/nr-hydrometric-rating-curve';
    process.env.REPOSITORY = 'bcgov/nr-hydrometric-rating-curve';
    process.env.INPUT_REVISION = headSha;
    process.env.REVISION = headSha;
    process.env.DIR = repoDir;
    process.env.INPUT_DIR = repoDir;
    delete process.env.GITHUB_TOKEN;
    delete process.env.INPUT_TOKEN;
    delete process.env.TOKEN;

    // Must reject because GITHUB_REF is not refs/pull/<num>/merge, so baseSha is not accepted as merge SHA
    await assert.rejects(() => runMain(), /process\.exit called with code 1/);
  } finally {
    global.fetch = origFetch;
    process.exit = origExit;
    process.chdir(cwd);
    restoreEnv(saved);
    fs.rmSync(repoDir, { recursive: true, force: true });
  }
});

test('runMain resolves PR image for squash-merged commit on main when image revision is synthetic PR merge commit', async () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const os = require('node:os');
  const { runMain } = require('../index.js');
  const origFetch = global.fetch;
  const origExit = process.exit;
  const saved = snapshotEnv();
  const cwd = process.cwd();

  const repoDir = fs.mkdtempSync(path.join(os.tmpdir(), 'squash-test-'));
  try {
    process.exit = (code) => {
      throw new Error(`process.exit called with code ${code}`);
    };
    process.chdir(repoDir);
    execFileSync('git', ['init', '-b', 'main'], { encoding: 'utf8' });
    execFileSync('git', ['config', 'user.name', 'test'], { encoding: 'utf8' });
    execFileSync('git', ['config', 'user.email', 'test@example.com'], { encoding: 'utf8' });
    execFileSync('git', ['remote', 'add', 'origin', 'https://github.com/miniontech/vexilon.git'], { encoding: 'utf8' });

    fs.writeFileSync(path.join(repoDir, 'file.txt'), 'base');
    execFileSync('git', ['add', '.'], { encoding: 'utf8' });
    execFileSync('git', ['commit', '-m', 'initial base commit'], { encoding: 'utf8' });

    fs.writeFileSync(path.join(repoDir, 'file.txt'), 'squash-change');
    execFileSync('git', ['add', '.'], { encoding: 'utf8' });
    execFileSync('git', ['commit', '-m', 'chore(deps): update dependency uv to v0.12.9 (#662)'], {
      encoding: 'utf8'
    });

    const squashSha = execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
    const headSha = '746d271f4975c5d5572129d3ecd3bc92416b0f90';
    const syntheticMergeSha = 'b48f3d437680b943cab0121ec5b043e2494a0d6e';
    const expectedDigest = 'sha256:35ccf554ed49dd01b29cf7f3a879f869d2a06b2288bddd6acdee4613f24aed68';

    global.fetch = async (url, opts) => {
      // GitHub API commit pulls lookup
      if (url.includes(`/commits/${squashSha}/pulls`)) {
        return {
          ok: true,
          status: 200,
          json: async () => [
            {
              number: 662,
              head: { sha: headSha },
              merge_commit_sha: squashSha,
              title: 'chore(deps): update dependency uv to v0.12.9'
            }
          ]
        };
      }
      // GitHub API commit lookup for synthetic merge commit
      if (url.includes(`/commits/${syntheticMergeSha}`)) {
        return {
          ok: true,
          status: 200,
          json: async () => ({
            sha: syntheticMergeSha,
            parents: [{ sha: '831dc67b44b37bd8f4ffa928c7386c4e9be8838d' }, { sha: headSha }],
            commit: {
              message: `Merge ${headSha} into 831dc67b44b37bd8f4ffa928c7386c4e9be8838d`
            }
          })
        };
      }
      // GHCR auth
      if (url.endsWith('/manifests/latest')) {
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
      if (url.includes('/token?')) {
        return {
          ok: true,
          status: 200,
          headers: { get: () => null },
          json: async () => ({ token: 'mock-token' })
        };
      }
      // GHCR manifest for pr-662
      if (url.includes('/manifests/pr-662')) {
        return {
          ok: true,
          status: 200,
          headers: {
            get: (h) => (h.toLowerCase() === 'docker-content-digest' ? expectedDigest : null)
          },
          json: async () => ({
            schemaVersion: 2,
            mediaType: 'application/vnd.oci.image.index.v1+json',
            manifests: [
              {
                mediaType: 'application/vnd.oci.image.manifest.v1+json',
                digest: expectedDigest,
                platform: { architecture: 'amd64', os: 'linux' }
              }
            ]
          })
        };
      }
      // GHCR child manifest
      if (url.includes(`/manifests/${expectedDigest}`)) {
        return {
          ok: true,
          status: 200,
          headers: {
            get: (h) => (h.toLowerCase() === 'docker-content-digest' ? expectedDigest : null)
          },
          json: async () => ({
            schemaVersion: 2,
            mediaType: 'application/vnd.oci.image.manifest.v1+json',
            annotations: {
              'org.opencontainers.image.revision': syntheticMergeSha,
              'org.opencontainers.image.version': 'pr-662',
              'org.opencontainers.image.source': 'https://github.com/MinionTech/vexilon',
              'org.opencontainers.image.created': '2026-09-07T20:56:16Z'
            }
          })
        };
      }

      return {
        ok: false,
        status: 404,
        headers: { get: () => null },
        json: async () => ({})
      };
    };

    const out = path.join(repoDir, 'github_output');
    process.env.GITHUB_ACTIONS = 'true';
    process.env.GITHUB_REPOSITORY = 'miniontech/vexilon';
    process.env.GITHUB_OUTPUT = out;
    process.env.GITHUB_EVENT_NAME = 'push';
    process.env.GITHUB_REF = 'refs/heads/main';
    process.env.GITHUB_SHA = squashSha;
    process.env.INPUT_PACKAGE = 'agnav';
    process.env.PACKAGE = 'agnav';
    process.env.INPUT_REPOSITORY = 'miniontech/vexilon';
    process.env.REPOSITORY = 'miniontech/vexilon';
    process.env.INPUT_REVISION = squashSha;
    process.env.REVISION = squashSha;
    process.env.DIR = repoDir;
    process.env.INPUT_DIR = repoDir;
    process.env.INPUT_TOKEN = 'mock-token';

    await runMain();

    const outputContent = fs.readFileSync(out, 'utf8');
    assert.match(outputContent, new RegExp(expectedDigest), 'output must contain resolved image digest');
    assert.match(outputContent, /pr=662/, 'output must contain resolved PR number 662');
  } finally {
    global.fetch = origFetch;
    process.exit = origExit;
    process.chdir(cwd);
    restoreEnv(saved);
    fs.rmSync(repoDir, { recursive: true, force: true });
  }
});

test('probeTag resolves synthetic PR merge revision via OCI version and source annotations when unauthenticated', async () => {
  const { probeTag, matchesCandidate } = require('../index.js');
  const origFetch = global.fetch;

  const squashSha = '07ac254b246bcb9829d95827a17c92cba219bf92';
  const headSha = '746d271f4975c5d5572129d3ecd3bc92416b0f90';
  const syntheticMergeSha = 'b48f3d437680b943cab0121ec5b043e2494a0d6e';
  const expectedDigest = 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  global.fetch = async (url) => {
    if (url.includes('/manifests/pr-662')) {
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
            'org.opencontainers.image.revision': syntheticMergeSha,
            'org.opencontainers.image.version': 'pr-662',
            'org.opencontainers.image.source': 'https://github.com/MinionTech/vexilon',
            'org.opencontainers.image.created': '2026-09-07T20:56:16Z'
          }
        })
      };
    }
    return { ok: false, status: 404, headers: { get: () => null }, json: async () => ({}) };
  };

  try {
    const candidates = [squashSha];
    const prMap = { [squashSha]: headSha };
    const prNumMap = { [squashSha]: '662' };
    const prMergeMap = {};

    const res = await probeTag(
      'miniontech/vexilon/agnav',
      'pr-662',
      'mock-bearer',
      'ghcr.io',
      candidates,
      prMap,
      prNumMap,
      {},
      {},
      false,
      prMergeMap,
      null, // No token (unauthenticated / offline)
      'miniontech/vexilon'
    );

    assert.ok(res, 'probeTag should succeed via OCI version/source annotation match');
    assert.strictEqual(res.sha, squashSha);
    assert.strictEqual(res.digest, expectedDigest);
    assert.strictEqual(
      matchesCandidate(syntheticMergeSha, 'pr-662', candidates, prMap, prNumMap, prMergeMap),
      true,
      'matchesCandidate should accept verified synthetic merge sha'
    );
  } finally {
    global.fetch = origFetch;
  }
});

test('probeTag and matchesCandidate strictly reject unrelated revision even if tagged pr-99 and token present', async () => {
  const { probeTag, matchesCandidate } = require('../index.js');
  const origFetch = global.fetch;

  const squashSha = '07ac254b246bcb9829d95827a17c92cba219bf92';
  const headSha = '746d271f4975c5d5572129d3ecd3bc92416b0f90';
  const unrelatedSha = 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef';
  const expectedDigest = 'sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';

  global.fetch = async (url) => {
    // GitHub API commit lookup for unrelated commit
    if (url.includes(`/commits/${unrelatedSha}`)) {
      return {
        ok: true,
        status: 200,
        json: async () => ({
          sha: unrelatedSha,
          parents: [{ sha: '1111111111111111111111111111111111111111' }, { sha: '2222222222222222222222222222222222222222' }],
          commit: { message: 'totally unrelated commit' }
        })
      };
    }
    if (url.includes('/manifests/pr-662')) {
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
            'org.opencontainers.image.revision': unrelatedSha,
            'org.opencontainers.image.version': 'pr-999', // mismatched PR version
            'org.opencontainers.image.source': 'https://github.com/MinionTech/vexilon'
          }
        })
      };
    }
    return { ok: false, status: 404, headers: { get: () => null }, json: async () => ({}) };
  };

  try {
    const candidates = [squashSha];
    const prMap = { [squashSha]: headSha };
    const prNumMap = { [squashSha]: '662' };
    const prMergeMap = {};

    const res = await probeTag(
      'miniontech/vexilon/agnav',
      'pr-662',
      'mock-bearer',
      'ghcr.io',
      candidates,
      prMap,
      prNumMap,
      {},
      {},
      false,
      prMergeMap,
      'mock-token',
      'miniontech/vexilon'
    );

    assert.strictEqual(res, null, 'probeTag must reject unrelated revision');
    assert.strictEqual(
      matchesCandidate(unrelatedSha, 'pr-662', candidates, prMap, prNumMap, prMergeMap),
      false,
      'matchesCandidate must reject unrelated revision'
    );
  } finally {
    global.fetch = origFetch;
  }
});

test('runMain resolves multiple packages (frontend, rctool) on squash-merged main branch', async () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const os = require('node:os');
  const { runMain } = require('../index.js');
  const origFetch = global.fetch;
  const origExit = process.exit;
  const saved = snapshotEnv();
  const cwd = process.cwd();

  const repoDir = fs.mkdtempSync(path.join(os.tmpdir(), 'multi-pkg-test-'));
  try {
    process.exit = (code) => {
      throw new Error(`process.exit called with code ${code}`);
    };
    process.chdir(repoDir);
    execFileSync('git', ['init', '-b', 'main'], { encoding: 'utf8' });
    execFileSync('git', ['config', 'user.name', 'test'], { encoding: 'utf8' });
    execFileSync('git', ['config', 'user.email', 'test@example.com'], { encoding: 'utf8' });
    execFileSync('git', ['remote', 'add', 'origin', 'https://github.com/bcgov/nr-hydrometric-rating-curve.git'], { encoding: 'utf8' });

    fs.writeFileSync(path.join(repoDir, 'file.txt'), 'base');
    execFileSync('git', ['add', '.'], { encoding: 'utf8' });
    execFileSync('git', ['commit', '-m', 'initial base commit'], { encoding: 'utf8' });

    fs.writeFileSync(path.join(repoDir, 'file.txt'), 'squash');
    execFileSync('git', ['add', '.'], { encoding: 'utf8' });
    execFileSync('git', ['commit', '-m', 'chore(deps): lock file maintenance (#383)'], {
      encoding: 'utf8'
    });

    const squashSha = execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
    const headSha = '637f189b2e0aed0a8d0b4af224f62af1ffd1bd50';
    const syntheticMergeSha = '64a5a332364b27b8998f1af66926cda2cc667ddd';
    const frontendDigest = 'sha256:1111111111111111111111111111111111111111111111111111111111111111';
    const rctoolDigest = 'sha256:2222222222222222222222222222222222222222222222222222222222222222';

    global.fetch = async (url) => {
      if (url.includes(`/commits/${squashSha}/pulls`)) {
        return {
          ok: true,
          status: 200,
          json: async () => [
            {
              number: 383,
              head: { sha: headSha },
              merge_commit_sha: squashSha,
              title: 'chore(deps): lock file maintenance'
            }
          ]
        };
      }
      if (url.includes(`/commits/${syntheticMergeSha}`)) {
        return {
          ok: true,
          status: 200,
          json: async () => ({
            sha: syntheticMergeSha,
            parents: [{ sha: '8c8d1730b7e8b2ac0510d50036bcb528ac3ea2e6' }, { sha: headSha }],
            commit: { message: `Merge ${headSha} into 8c8d1730b7e8b2ac0510d50036bcb528ac3ea2e6` }
          })
        };
      }
      if (url.endsWith('/manifests/latest')) {
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
      if (url.includes('/token?')) {
        return {
          ok: true,
          status: 200,
          headers: { get: () => null },
          json: async () => ({ token: 'mock-token' })
        };
      }
      // Manifests for frontend
      if (url.includes('/frontend/manifests/pr-383')) {
        return {
          ok: true,
          status: 200,
          headers: {
            get: (h) => (h.toLowerCase() === 'docker-content-digest' ? frontendDigest : null)
          },
          json: async () => ({
            schemaVersion: 2,
            mediaType: 'application/vnd.oci.image.manifest.v1+json',
            digest: frontendDigest,
            annotations: {
              'org.opencontainers.image.revision': syntheticMergeSha,
              'org.opencontainers.image.version': 'pr-383',
              'org.opencontainers.image.source': 'https://github.com/bcgov/nr-hydrometric-rating-curve'
            }
          })
        };
      }
      // Manifests for rctool
      if (url.includes('/rctool/manifests/pr-383')) {
        return {
          ok: true,
          status: 200,
          headers: {
            get: (h) => (h.toLowerCase() === 'docker-content-digest' ? rctoolDigest : null)
          },
          json: async () => ({
            schemaVersion: 2,
            mediaType: 'application/vnd.oci.image.manifest.v1+json',
            digest: rctoolDigest,
            annotations: {
              'org.opencontainers.image.revision': syntheticMergeSha,
              'org.opencontainers.image.version': 'pr-383',
              'org.opencontainers.image.source': 'https://github.com/bcgov/nr-hydrometric-rating-curve'
            }
          })
        };
      }
      return { ok: false, status: 404, headers: { get: () => null }, json: async () => ({}) };
    };

    const out = path.join(repoDir, 'github_output');
    process.env.GITHUB_ACTIONS = 'true';
    process.env.GITHUB_REPOSITORY = 'bcgov/nr-hydrometric-rating-curve';
    process.env.GITHUB_OUTPUT = out;
    process.env.GITHUB_EVENT_NAME = 'push';
    process.env.GITHUB_REF = 'refs/heads/main';
    process.env.GITHUB_SHA = squashSha;
    process.env.INPUT_PACKAGE = 'frontend, rctool';
    process.env.PACKAGE = 'frontend, rctool';
    process.env.INPUT_REPOSITORY = 'bcgov/nr-hydrometric-rating-curve';
    process.env.REPOSITORY = 'bcgov/nr-hydrometric-rating-curve';
    process.env.INPUT_REVISION = squashSha;
    process.env.REVISION = squashSha;
    process.env.DIR = repoDir;
    process.env.INPUT_DIR = repoDir;
    process.env.INPUT_TOKEN = 'mock-token';

    await runMain();

    const outputContent = fs.readFileSync(out, 'utf8');
    assert.match(outputContent, new RegExp(frontendDigest), 'output must contain frontend digest');
    assert.match(outputContent, new RegExp(rctoolDigest), 'output must contain rctool digest');
    assert.match(outputContent, /pr=383/, 'output must contain resolved PR number 383');
  } finally {
    global.fetch = origFetch;
    process.exit = origExit;
    process.chdir(cwd);
    restoreEnv(saved);
    fs.rmSync(repoDir, { recursive: true, force: true });
  }
});

test('runMain resolves PR image when running on PR head commit checkout', async () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const os = require('node:os');
  const { runMain } = require('../index.js');
  const origFetch = global.fetch;
  const origExit = process.exit;
  const saved = snapshotEnv();
  const cwd = process.cwd();

  const repoDir = fs.mkdtempSync(path.join(os.tmpdir(), 'pr-head-test-'));
  try {
    process.exit = (code) => {
      throw new Error(`process.exit called with code ${code}`);
    };
    process.chdir(repoDir);
    execFileSync('git', ['init', '-b', 'main'], { encoding: 'utf8' });
    execFileSync('git', ['config', 'user.name', 'test'], { encoding: 'utf8' });
    execFileSync('git', ['config', 'user.email', 'test@example.com'], { encoding: 'utf8' });
    execFileSync('git', ['remote', 'add', 'origin', 'https://github.com/bcgov/nr-hydrometric-rating-curve.git'], { encoding: 'utf8' });

    fs.writeFileSync(path.join(repoDir, 'file.txt'), 'base');
    execFileSync('git', ['add', '.'], { encoding: 'utf8' });
    execFileSync('git', ['commit', '-m', 'base commit'], { encoding: 'utf8' });

    execFileSync('git', ['checkout', '-b', 'renovate/feature'], { encoding: 'utf8' });
    fs.writeFileSync(path.join(repoDir, 'file.txt'), 'feature update');
    execFileSync('git', ['add', '.'], { encoding: 'utf8' });
    execFileSync('git', ['commit', '-m', 'feature commit'], { encoding: 'utf8' });

    const headSha = execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
    const syntheticMergeSha = '7777777777777777777777777777777777777777';
    const expectedDigest = 'sha256:3333333333333333333333333333333333333333333333333333333333333333';

    global.fetch = async (url) => {
      if (url.includes(`/commits/${headSha}/pulls`)) {
        return {
          ok: true,
          status: 200,
          json: async () => [
            {
              number: 400,
              head: { sha: headSha },
              title: 'feature PR'
            }
          ]
        };
      }
      if (url.includes(`/commits/${syntheticMergeSha}`)) {
        return {
          ok: true,
          status: 200,
          json: async () => ({
            sha: syntheticMergeSha,
            parents: [{ sha: 'base-sha' }, { sha: headSha }],
            commit: { message: `Merge ${headSha} into base-sha` }
          })
        };
      }
      if (url.endsWith('/manifests/latest')) {
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
      if (url.includes('/token?')) {
        return {
          ok: true,
          status: 200,
          headers: { get: () => null },
          json: async () => ({ token: 'mock-token' })
        };
      }
      if (url.includes('/manifests/pr-400')) {
        return {
          ok: true,
          status: 200,
          headers: {
            get: (h) => (h.toLowerCase() === 'docker-content-digest' ? expectedDigest : null)
          },
          json: async () => ({
            schemaVersion: 2,
            mediaType: 'application/vnd.oci.image.manifest.v1+json',
            digest: expectedDigest,
            annotations: {
              'org.opencontainers.image.revision': syntheticMergeSha,
              'org.opencontainers.image.version': 'pr-400',
              'org.opencontainers.image.source': 'https://github.com/bcgov/nr-hydrometric-rating-curve'
            }
          })
        };
      }
      return { ok: false, status: 404, headers: { get: () => null }, json: async () => ({}) };
    };

    const out = path.join(repoDir, 'github_output');
    process.env.GITHUB_ACTIONS = 'true';
    process.env.GITHUB_REPOSITORY = 'bcgov/nr-hydrometric-rating-curve';
    process.env.GITHUB_OUTPUT = out;
    process.env.GITHUB_EVENT_NAME = 'pull_request';
    process.env.GITHUB_REF = 'refs/pull/400/head';
    process.env.GITHUB_SHA = headSha;
    process.env.INPUT_PACKAGE = 'frontend';
    process.env.PACKAGE = 'frontend';
    process.env.INPUT_REPOSITORY = 'bcgov/nr-hydrometric-rating-curve';
    process.env.REPOSITORY = 'bcgov/nr-hydrometric-rating-curve';
    process.env.INPUT_REVISION = headSha;
    process.env.REVISION = headSha;
    process.env.DIR = repoDir;
    process.env.INPUT_DIR = repoDir;
    process.env.INPUT_TOKEN = 'mock-token';

    await runMain();

    const outputContent = fs.readFileSync(out, 'utf8');
    assert.match(outputContent, new RegExp(expectedDigest), 'output must contain resolved image digest');
    assert.match(outputContent, /pr=400/, 'output must contain resolved PR number 400');
  } finally {
    global.fetch = origFetch;
    process.exit = origExit;
    process.chdir(cwd);
    restoreEnv(saved);
    fs.rmSync(repoDir, { recursive: true, force: true });
  }
});

test('runMain resolves PR image when squash commit is walked back via max_depth', async () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const os = require('node:os');
  const { runMain } = require('../index.js');
  const origFetch = global.fetch;
  const origExit = process.exit;
  const saved = snapshotEnv();
  const cwd = process.cwd();

  const repoDir = fs.mkdtempSync(path.join(os.tmpdir(), 'walkback-test-'));
  try {
    process.exit = (code) => {
      throw new Error(`process.exit called with code ${code}`);
    };
    process.chdir(repoDir);
    execFileSync('git', ['init', '-b', 'main'], { encoding: 'utf8' });
    execFileSync('git', ['config', 'user.name', 'test'], { encoding: 'utf8' });
    execFileSync('git', ['config', 'user.email', 'test@example.com'], { encoding: 'utf8' });
    execFileSync('git', ['remote', 'add', 'origin', 'https://github.com/bcgov/nr-hydrometric-rating-curve.git'], { encoding: 'utf8' });

    fs.writeFileSync(path.join(repoDir, 'file.txt'), 'base');
    execFileSync('git', ['add', '.'], { encoding: 'utf8' });
    execFileSync('git', ['commit', '-m', 'initial commit'], { encoding: 'utf8' });

    // Commit 1: squash merge commit of PR #500
    fs.writeFileSync(path.join(repoDir, 'file.txt'), 'feature');
    execFileSync('git', ['add', '.'], { encoding: 'utf8' });
    execFileSync('git', ['commit', '-m', 'feat: cool feature (#500)'], { encoding: 'utf8' });
    const squashSha = execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();

    // Commit 2: docs update (no image)
    fs.writeFileSync(path.join(repoDir, 'README.md'), 'docs');
    execFileSync('git', ['add', '.'], { encoding: 'utf8' });
    execFileSync('git', ['commit', '-m', 'docs: update readme'], { encoding: 'utf8' });

    // Commit 3: chore bump (no image)
    fs.writeFileSync(path.join(repoDir, 'version.txt'), '1.0.1');
    execFileSync('git', ['add', '.'], { encoding: 'utf8' });
    execFileSync('git', ['commit', '-m', 'chore: bump version'], { encoding: 'utf8' });
    const headCommit = execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();

    const prHeadSha = '5555555555555555555555555555555555555555';
    const syntheticMergeSha = '6666666666666666666666666666666666666666';
    const expectedDigest = 'sha256:5555555555555555555555555555555555555555555555555555555555555555';

    global.fetch = async (url) => {
      if (url.includes(`/commits/${squashSha}/pulls`)) {
        return {
          ok: true,
          status: 200,
          json: async () => [
            {
              number: 500,
              head: { sha: prHeadSha },
              merge_commit_sha: squashSha,
              title: 'feat: cool feature'
            }
          ]
        };
      }
      if (url.includes(`/commits/${syntheticMergeSha}`)) {
        return {
          ok: true,
          status: 200,
          json: async () => ({
            sha: syntheticMergeSha,
            parents: [{ sha: 'base-sha' }, { sha: prHeadSha }],
            commit: { message: `Merge ${prHeadSha} into base-sha` }
          })
        };
      }
      if (url.endsWith('/manifests/latest')) {
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
      if (url.includes('/token?')) {
        return {
          ok: true,
          status: 200,
          headers: { get: () => null },
          json: async () => ({ token: 'mock-token' })
        };
      }
      if (url.includes('/manifests/pr-500')) {
        return {
          ok: true,
          status: 200,
          headers: {
            get: (h) => (h.toLowerCase() === 'docker-content-digest' ? expectedDigest : null)
          },
          json: async () => ({
            schemaVersion: 2,
            mediaType: 'application/vnd.oci.image.manifest.v1+json',
            digest: expectedDigest,
            annotations: {
              'org.opencontainers.image.revision': syntheticMergeSha,
              'org.opencontainers.image.version': 'pr-500',
              'org.opencontainers.image.source': 'https://github.com/bcgov/nr-hydrometric-rating-curve'
            }
          })
        };
      }
      return { ok: false, status: 404, headers: { get: () => null }, json: async () => ({}) };
    };

    const out = path.join(repoDir, 'github_output');
    process.env.GITHUB_ACTIONS = 'true';
    process.env.GITHUB_REPOSITORY = 'bcgov/nr-hydrometric-rating-curve';
    process.env.GITHUB_OUTPUT = out;
    process.env.GITHUB_EVENT_NAME = 'push';
    process.env.GITHUB_REF = 'refs/heads/main';
    process.env.GITHUB_SHA = headCommit;
    process.env.INPUT_PACKAGE = 'frontend';
    process.env.PACKAGE = 'frontend';
    process.env.INPUT_REPOSITORY = 'bcgov/nr-hydrometric-rating-curve';
    process.env.REPOSITORY = 'bcgov/nr-hydrometric-rating-curve';
    process.env.INPUT_REVISION = headCommit;
    process.env.REVISION = headCommit;
    process.env.MAX_DEPTH = '5';
    process.env.INPUT_MAX_DEPTH = '5';
    process.env.DIR = repoDir;
    process.env.INPUT_DIR = repoDir;
    process.env.INPUT_TOKEN = 'mock-token';

    await runMain();

    const outputContent = fs.readFileSync(out, 'utf8');
    assert.match(outputContent, new RegExp(expectedDigest), 'must walk back and find squash PR image');
    assert.match(outputContent, /pr=500/, 'must set resolved PR number 500');
  } finally {
    global.fetch = origFetch;
    process.exit = origExit;
    process.chdir(cwd);
    restoreEnv(saved);
    fs.rmSync(repoDir, { recursive: true, force: true });
  }
});

test('runMain rejects stale ancestor image when pivot maps to a different PR (Issue #203)', async () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const os = require('node:os');
  const { runMain } = require('../index.js');
  const origFetch = global.fetch;
  const origExit = process.exit;
  const origLog = console.log;
  const origErr = console.error;
  const saved = snapshotEnv();
  const cwd = process.cwd();

  const repoDir = fs.mkdtempSync(path.join(os.tmpdir(), 'stale-pr-test-'));
  try {
    let exitCode;
    process.exit = (code) => {
      exitCode = code;
      throw new Error('__exit__');
    };
    const logs = [];
    console.log = (...a) => logs.push(a.join(' '));
    console.error = (...a) => logs.push(a.join(' '));

    process.chdir(repoDir);
    execFileSync('git', ['init', '-b', 'main'], { encoding: 'utf8' });
    execFileSync('git', ['config', 'user.name', 'test'], { encoding: 'utf8' });
    execFileSync('git', ['config', 'user.email', 'test@example.com'], { encoding: 'utf8' });
    execFileSync('git', ['remote', 'add', 'origin', 'https://github.com/bcgov/nr-hydrometric-rating-curve.git'], {
      encoding: 'utf8'
    });

    fs.writeFileSync(path.join(repoDir, 'file.txt'), 'base');
    execFileSync('git', ['add', '.'], { encoding: 'utf8' });
    execFileSync('git', ['commit', '-m', 'initial commit'], { encoding: 'utf8' });

    fs.writeFileSync(path.join(repoDir, 'file.txt'), 'lockfile');
    execFileSync('git', ['add', '.'], { encoding: 'utf8' });
    execFileSync('git', ['commit', '-m', 'chore(deps): lock file maintenance (#383)'], { encoding: 'utf8' });
    const ancestorSha = execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();

    fs.writeFileSync(path.join(repoDir, 'file.txt'), 'feature-379');
    execFileSync('git', ['add', '.'], { encoding: 'utf8' });
    execFileSync('git', ['commit', '-m', 'feat: hydrometric change (#379)'], { encoding: 'utf8' });
    const pivotSha = execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();

    const staleDigest = 'sha256:3833833833833833833833833833833833833833833833833833833833833833';

    global.fetch = async (url) => {
      if (url.endsWith('/manifests/latest')) {
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
      if (url.includes('/token?')) {
        return {
          ok: true,
          status: 200,
          headers: { get: () => null },
          json: async () => ({ token: 'mock-token' })
        };
      }
      if (url.includes('/manifests/pr-383') || url.includes(`/manifests/sha-${ancestorSha.slice(0, 7)}`)) {
        return {
          ok: true,
          status: 200,
          headers: {
            get: (h) => (h.toLowerCase() === 'docker-content-digest' ? staleDigest : null)
          },
          json: async () => ({
            mediaType: 'application/vnd.oci.image.manifest.v1+json',
            digest: staleDigest,
            annotations: {
              'org.opencontainers.image.revision': ancestorSha,
              'org.opencontainers.image.version': 'pr-383',
              'org.opencontainers.image.source': 'https://github.com/bcgov/nr-hydrometric-rating-curve'
            }
          })
        };
      }
      return { ok: false, status: 404, headers: { get: () => null }, json: async () => ({}) };
    };

    const out = path.join(repoDir, 'github_output');
    process.env.GITHUB_ACTIONS = 'true';
    process.env.GITHUB_REPOSITORY = 'bcgov/nr-hydrometric-rating-curve';
    process.env.GITHUB_OUTPUT = out;
    process.env.GITHUB_EVENT_NAME = 'push';
    process.env.GITHUB_REF = 'refs/heads/main';
    process.env.GITHUB_SHA = pivotSha;
    process.env.INPUT_PACKAGE = 'frontend';
    process.env.PACKAGE = 'frontend';
    process.env.INPUT_REPOSITORY = 'bcgov/nr-hydrometric-rating-curve';
    process.env.REPOSITORY = 'bcgov/nr-hydrometric-rating-curve';
    process.env.INPUT_REVISION = pivotSha;
    process.env.REVISION = pivotSha;
    process.env.MAX_DEPTH = '5';
    process.env.INPUT_MAX_DEPTH = '5';
    process.env.DIR = repoDir;
    process.env.INPUT_DIR = repoDir;
    process.env.INPUT_TOKEN = 'mock-token';

    await assert.rejects(() => runMain(), /__exit__/);
    assert.strictEqual(exitCode, 1, 'must fail instead of deploying PR 383');
    const joined = logs.join('\n');
    assert.match(joined, /mystery deployment/, 'must name mystery-deployment halt');
    assert.match(joined, new RegExp(pivotSha), 'must name the target revision');
    const outputContent = fs.readFileSync(out, 'utf8');
    assert.doesNotMatch(outputContent, new RegExp(staleDigest), 'must not emit ancestor digest');
    assert.doesNotMatch(outputContent, /pr=383/, 'must not emit ancestor PR number');
  } finally {
    global.fetch = origFetch;
    process.exit = origExit;
    console.log = origLog;
    console.error = origErr;
    process.chdir(cwd);
    restoreEnv(saved);
    fs.rmSync(repoDir, { recursive: true, force: true });
  }
});

test('probeTag rejects image when source repository is mismatched (security check)', async () => {
  const { probeTag, matchesCandidate } = require('../index.js');
  const origFetch = global.fetch;

  const candSha = '07ac254b246bcb9829d95827a17c92cba219bf92';
  const headSha = '746d271f4975c5d5572129d3ecd3bc92416b0f90';
  const spoofedSha = '4444444444444444444444444444444444444444';
  const expectedDigest = 'sha256:9999999999999999999999999999999999999999999999999999999999999999';

  global.fetch = async (url) => {
    if (url.includes('/manifests/pr-662')) {
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
            'org.opencontainers.image.revision': spoofedSha,
            'org.opencontainers.image.version': 'pr-662',
            'org.opencontainers.image.source': 'https://github.com/attacker/malicious'
          }
        })
      };
    }
    return { ok: false, status: 404, headers: { get: () => null }, json: async () => ({}) };
  };

  try {
    const candidates = [candSha];
    const prMap = { [candSha]: headSha };
    const prNumMap = { [candSha]: '662' };
    const prMergeMap = {};

    const res = await probeTag(
      'miniontech/vexilon/agnav',
      'pr-662',
      'mock-bearer',
      'ghcr.io',
      candidates,
      prMap,
      prNumMap,
      {},
      {},
      false,
      prMergeMap,
      null, // unauthenticated
      'miniontech/vexilon' // expected repo
    );

    assert.strictEqual(res, null, 'probeTag must reject mismatched source repository');
  } finally {
    global.fetch = origFetch;
  }
});

test('probeTag rejects image with missing revision label even if tagged pr-662', async () => {
  const { probeTag } = require('../index.js');
  const origFetch = global.fetch;

  const candSha = '07ac254b246bcb9829d95827a17c92cba219bf92';
  const headSha = '746d271f4975c5d5572129d3ecd3bc92416b0f90';
  const expectedDigest = 'sha256:8888888888888888888888888888888888888888888888888888888888888888';

  global.fetch = async (url) => {
    if (url.includes('/manifests/pr-662')) {
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
            // Missing org.opencontainers.image.revision entirely!
            'org.opencontainers.image.version': 'pr-662',
            'org.opencontainers.image.source': 'https://github.com/MinionTech/vexilon'
          }
        })
      };
    }
    return { ok: false, status: 404, headers: { get: () => null }, json: async () => ({}) };
  };

  try {
    const candidates = [candSha];
    const prMap = { [candSha]: headSha };
    const prNumMap = { [candSha]: '662' };
    const prMergeMap = {};

    const res = await probeTag(
      'miniontech/vexilon/agnav',
      'pr-662',
      'mock-bearer',
      'ghcr.io',
      candidates,
      prMap,
      prNumMap,
      {},
      {},
      false,
      prMergeMap,
      'mock-token',
      'miniontech/vexilon'
    );

    assert.strictEqual(res, null, 'probeTag must reject image without revision label');
  } finally {
    global.fetch = origFetch;
  }
});

test('probeTag verifies synthetic PR merge revision via local git parentage without API token', async () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const os = require('node:os');
  const { probeTag, matchesCandidate } = require('../index.js');
  const origFetch = global.fetch;
  const cwd = process.cwd();

  const repoDir = fs.mkdtempSync(path.join(os.tmpdir(), 'git-parent-test-'));
  try {
    process.chdir(repoDir);
    execFileSync('git', ['init', '-b', 'main'], { encoding: 'utf8' });
    execFileSync('git', ['config', 'user.name', 'test'], { encoding: 'utf8' });
    execFileSync('git', ['config', 'user.email', 'test@example.com'], { encoding: 'utf8' });

    fs.writeFileSync(path.join(repoDir, 'file.txt'), 'base');
    execFileSync('git', ['add', '.'], { encoding: 'utf8' });
    execFileSync('git', ['commit', '-m', 'base commit'], { encoding: 'utf8' });

    execFileSync('git', ['checkout', '-b', 'pr-branch'], { encoding: 'utf8' });
    fs.writeFileSync(path.join(repoDir, 'pr.txt'), 'pr code');
    execFileSync('git', ['add', '.'], { encoding: 'utf8' });
    execFileSync('git', ['commit', '-m', 'pr head commit'], { encoding: 'utf8' });
    const prHeadSha = execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();

    execFileSync('git', ['checkout', 'main'], { encoding: 'utf8' });
    // Create a merge commit locally simulating synthetic merge ref
    execFileSync('git', ['merge', '--no-ff', 'pr-branch', '-m', `Merge ${prHeadSha} into main`], {
      encoding: 'utf8'
    });
    const mergeSha = execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();

    const expectedDigest = 'sha256:7777777777777777777777777777777777777777777777777777777777777777';

    global.fetch = async (url) => {
      if (url.includes('/manifests/pr-123')) {
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
              'org.opencontainers.image.revision': mergeSha
            }
          })
        };
      }
      return { ok: false, status: 404, headers: { get: () => null }, json: async () => ({}) };
    };

    const candidates = [prHeadSha];
    const prMap = { [prHeadSha]: prHeadSha };
    const prNumMap = { [prHeadSha]: '123' };
    const prMergeMap = {};

    const res = await probeTag(
      'bcgov/repo/pkg',
      'pr-123',
      'mock-bearer',
      'ghcr.io',
      candidates,
      prMap,
      prNumMap,
      {},
      {},
      false,
      prMergeMap,
      null, // no API token
      'bcgov/repo'
    );

    assert.ok(res, 'probeTag must verify via local git parentage');
    assert.strictEqual(res.sha, prHeadSha);
    assert.strictEqual(res.digest, expectedDigest);
  } finally {
    global.fetch = origFetch;
    process.chdir(cwd);
    fs.rmSync(repoDir, { recursive: true, force: true });
  }
});

test('strict token input: consumes only INPUT_TOKEN and ignores legacy fallbacks', async () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const { runMain } = require('../index.js');
  const saved = snapshotEnv();
  const cwd = process.cwd();
  const origFetch = global.fetch;
  const origExit = process.exit;

  let capturedAuthHeaders = [];

  global.fetch = async (url, opts = {}) => {
    if (opts.headers && opts.headers.Authorization) {
      capturedAuthHeaders.push(opts.headers.Authorization);
    }
    if (url.includes('/manifests/')) {
      return {
        ok: false,
        status: 401,
        headers: {
          get: (h) => (h.toLowerCase() === 'www-authenticate' ? 'Bearer realm="https://ghcr.io/token",service="ghcr.io"' : null)
        }
      };
    }
    return {
      ok: true,
      status: 200,
      headers: {
        get: () => 'application/json'
      },
      json: async () => ({ token: 'mock-bearer' })
    };
  };

  process.exit = (code) => {
    throw new Error(`process.exit called with code ${code}`);
  };

  try {
    await withTempGitOrigin('file:///test-strict-token.git', async (dir) => {
      execFileSync('git', ['config', 'user.name', 'test'], { cwd: dir, stdio: 'ignore' });
      execFileSync('git', ['config', 'user.email', 'test@example.com'], { cwd: dir, stdio: 'ignore' });
      fs.writeFileSync(path.join(dir, 'file.txt'), 'x\n');
      execFileSync('git', ['add', '.'], { cwd: dir, stdio: 'ignore' });
      execFileSync('git', ['commit', '-m', 'init'], { cwd: dir, stdio: 'ignore' });

      const out = path.join(dir, 'github_output');
      process.env.GITHUB_ACTIONS = 'true';
      process.env.GITHUB_OUTPUT = out;
      process.env.GITHUB_EVENT_NAME = 'push';
      process.env.GITHUB_REPOSITORY = 'bcgov/foo';
      process.env.INPUT_PACKAGE = 'frontend';
      process.env.PACKAGE = 'frontend';
      process.env.INPUT_REPOSITORY = 'bcgov/foo';
      process.env.REPOSITORY = 'bcgov/foo';
      process.env.INPUT_REVISION = 'HEAD';
      process.env.REVISION = 'HEAD';
      process.env.DIR = dir;
      process.env.INPUT_DIR = dir;
      delete process.env.GITHUB_EVENT_PATH;

      process.env.TOKEN = 'legacy-token';
      process.env.INPUT_GITHUB_TOKEN = 'legacy-github-token';
      process.env.GITHUB_TOKEN = 'legacy-ambient-token';
      process.env.GH_TOKEN = 'legacy-gh-token';
      delete process.env.INPUT_TOKEN;

      capturedAuthHeaders = [];
      await assert.rejects(() => runMain(), /process\.exit called with code 1/);
      assert.ok(
        capturedAuthHeaders.every((h) => !/legacy/i.test(h)),
        'must not use legacy fallback environment variables'
      );

      process.env.INPUT_TOKEN = 'canonical-token';
      capturedAuthHeaders = [];
      await assert.rejects(() => runMain(), /process\.exit called with code 1/);
      assert.ok(
        capturedAuthHeaders.some((h) => h.includes('canonical-token')),
        `must use INPUT_TOKEN for authentication; saw ${JSON.stringify(capturedAuthHeaders)}`
      );
    });
  } finally {
    global.fetch = origFetch;
    process.exit = origExit;
    process.chdir(cwd);
    restoreEnv(saved);
  }
});

test('escapeMarkdownCell escapes backslashes first, then pipes', () => {
  const { escapeMarkdownCell } = require('../index.js');

  assert.strictEqual(escapeMarkdownCell('foo|bar'), 'foo\\|bar');
  assert.strictEqual(escapeMarkdownCell('foo\\bar'), 'foo\\\\bar');
  assert.strictEqual(escapeMarkdownCell('foo\\|bar'), 'foo\\\\\\|bar');
  assert.strictEqual(escapeMarkdownCell(''), '');
  assert.strictEqual(escapeMarkdownCell(null), '');
});

test('renderDiagnosticMarkdown renders candidate commits table and probed tags table with reasons', () => {
  const { renderDiagnosticMarkdown } = require('../index.js');

  const candidates = ['07ac254b246bcb9829d95827a17c92cba219bf92', '746d271f4975c5d5572129d3ecd3bc92416b0f90'];
  const prNumMap = { '07ac254b246bcb9829d95827a17c92cba219bf92': '662' };
  const prMap = { '07ac254b246bcb9829d95827a17c92cba219bf92': '746d271f4975c5d5572129d3ecd3bc92416b0f90' };
  const candidateMessages = {
    '07ac254b246bcb9829d95827a17c92cba219bf92': 'chore(deps): update dependency uv (#662)',
    '746d271f4975c5d5572129d3ecd3bc92416b0f90': 'feat: initial feature'
  };

  const probedTags = new Map([
    [
      'pr-662',
      {
        tag: 'pr-662',
        status: 200,
        reason: 'Revision mismatch',
        details: "Image revision '4444444' does not match candidate commit(s)"
      }
    ],
    [
      'sha-07ac254',
      {
        tag: 'sha-07ac254',
        status: 404,
        reason: 'Tag not found',
        details: 'Tag does not exist in registry'
      }
    ]
  ]);

  const packageDiagnostics = {
    frontend: {
      probedTags,
      bearerFailed: false,
      iterativeStatus: 'Scanned 5 tag(s); no matching candidate revision found'
    }
  };

  const md = renderDiagnosticMarkdown({
    registry: 'ghcr.io',
    candidates,
    missing: ['frontend'],
    packageDiagnostics,
    imagePaths: { frontend: 'bcgov/myapp/frontend' },
    prNumMap,
    prMap,
    candidateMessages,
    maxDepth: 10,
    sourceRepository: 'bcgov/myapp'
  });

  assert.ok(md.includes('### ❌ Image Tracker — Resolution Failure Diagnostics'));
  assert.ok(md.includes('| `07ac254` | #662 | `746d271` | chore(deps): update dependency uv (#662) |'));
  assert.ok(md.includes('| `746d271` | — | — | feat: initial feature |'));
  assert.ok(md.includes('#### 🔍 Candidate Tags Probed: `frontend` (`ghcr.io/bcgov/myapp/frontend`)'));
  assert.ok(md.includes('| `pr-662` | 200 OK | Revision mismatch | Image revision \'4444444\' does not match candidate commit(s) |'));
  assert.ok(md.includes('| `sha-07ac254` | 404 Not Found | Tag not found | Tag does not exist in registry |'));
  assert.ok(md.includes('*Iterative Scan*: Scanned 5 tag(s); no matching candidate revision found'));
  assert.ok(md.includes('Revision Mismatch (Stale Image Tag)'));
});

test('generateGuidance emits targeted troubleshooting guidance for all rejection categories', () => {
  const { generateGuidance } = require('../index.js');

  // Case 1: all 404s
  const g1 = generateGuidance({
    candidates: ['c1'],
    missing: ['api'],
    packageDiagnostics: {
      api: {
        probedTags: new Map([['sha-c1', { status: 404, reason: 'Tag not found' }]])
      }
    },
    maxDepth: 10
  });
  assert.ok(g1.some((i) => i.title.includes('Missing Image Tags (All Probes Returned HTTP 404)')));

  // Case 2: revision mismatch + missing label + depth reached
  const g2 = generateGuidance({
    candidates: ['c1', 'c2'],
    missing: ['api'],
    packageDiagnostics: {
      api: {
        probedTags: new Map([
          ['pr-10', { status: 200, reason: 'Revision mismatch' }],
          ['pr-11', { status: 200, reason: 'Missing revision label' }]
        ])
      }
    },
    maxDepth: 2
  });
  assert.ok(g2.some((i) => i.title.includes('Revision Mismatch')));
  assert.ok(g2.some((i) => i.title.includes('Missing OCI Revision Label')));
  assert.ok(g2.some((i) => i.title.includes('Search Depth Reached')));

  // Case 3: source mismatch + auth error
  const g3 = generateGuidance({
    candidates: ['c1'],
    missing: ['api'],
    packageDiagnostics: {
      api: {
        bearerFailed: true,
        probedTags: new Map([
          ['pr-10', { status: 200, reason: 'Source repository mismatch' }]
        ])
      }
    },
    maxDepth: 10,
    sourceRepository: 'bcgov/origin'
  });
  assert.ok(g3.some((i) => i.title.includes('Authentication / Permission Error')));
  assert.ok(g3.some((i) => i.title.includes('Source Repository Mismatch')));
});

test('renderDiagnosticConsole formats readable plain text diagnostic table', () => {
  const { renderDiagnosticConsole } = require('../index.js');

  const text = renderDiagnosticConsole({
    registry: 'ghcr.io',
    candidates: ['07ac254b246bcb9829d95827a17c92cba219bf92'],
    missing: ['frontend'],
    packageDiagnostics: {
      frontend: {
        probedTags: new Map([
          [
            'pr-662',
            {
              status: 200,
              reason: 'Revision mismatch',
              details: "Image revision '4444444' does not match"
            }
          ]
        ])
      }
    },
    imagePaths: { frontend: 'bcgov/myapp/frontend' },
    prNumMap: { '07ac254b246bcb9829d95827a17c92cba219bf92': '662' },
    candidateMessages: { '07ac254b246bcb9829d95827a17c92cba219bf92': 'chore: update uv' },
    maxDepth: 10,
    sourceRepository: 'bcgov/myapp'
  });

  assert.ok(text.includes('❌ Image Tracker — Resolution Failure Diagnostics'));
  assert.ok(text.includes('07ac254 | PR #662  | chore: update uv'));
  assert.ok(text.includes('pr-662'));
  assert.ok(text.includes('[200 OK]'));
  assert.ok(text.includes('Revision mismatch: Image revision \'4444444\' does not match'));
  assert.ok(text.includes('Targeted Guidance:'));
});

test('runMain writes diagnostic summary to GITHUB_STEP_SUMMARY on resolution failure', async () => {
  const fs = require('node:fs');
  const os = require('node:os');
  const path = require('node:path');
  const { execSync } = require('node:child_process');
  const { runMain } = require('../index.js');
  const origFetch = global.fetch;
  const saved = snapshotEnv();
  const cwd = process.cwd();
  const origExit = process.exit;
  let exitCode;
  process.exit = (code) => {
    exitCode = code;
    throw new Error('__exit__');
  };

  const repoDir = fs.mkdtempSync(path.join(os.tmpdir(), 'git-diag-fail-'));
  try {
    execSync('git init -b main', { cwd: repoDir });
    execSync('git config user.email "test@example.com"', { cwd: repoDir });
    execSync('git config user.name "Test"', { cwd: repoDir });
    fs.writeFileSync(path.join(repoDir, 'file.txt'), 'content');
    execSync('git add . && git commit -m "feat: initial commit"', { cwd: repoDir });
    const headSha = execSync('git rev-parse HEAD', { cwd: repoDir, encoding: 'utf8' }).trim();

    global.fetch = async () => ({
      ok: false,
      status: 404,
      statusText: 'Not Found',
      headers: { get: () => null },
      json: async () => ({})
    });

    const summaryFile = path.join(repoDir, 'step_summary.md');
    process.env.GITHUB_ACTIONS = 'true';
    process.env.GITHUB_STEP_SUMMARY = summaryFile;
    process.env.GITHUB_OUTPUT = path.join(repoDir, 'github_output');
    process.env.GITHUB_EVENT_NAME = 'push';
    process.env.GITHUB_REF = 'refs/heads/main';
    process.env.GITHUB_REPOSITORY = 'bcgov/foo';
    process.env.INPUT_PACKAGE = 'frontend';
    process.env.PACKAGE = 'frontend';
    process.env.INPUT_REPOSITORY = 'bcgov/foo';
    process.env.REPOSITORY = 'bcgov/foo';
    process.env.INPUT_REVISION = headSha;
    process.env.REVISION = headSha;
    process.env.DIR = repoDir;
    process.env.INPUT_DIR = repoDir;
    delete process.env.TOKEN;
    delete process.env.INPUT_TOKEN;

    await assert.rejects(() => runMain(), /__exit__/);
    assert.strictEqual(exitCode, 1);

    assert.ok(fs.existsSync(summaryFile), 'step summary file must exist');
    const summaryContent = fs.readFileSync(summaryFile, 'utf8');
    assert.ok(
      summaryContent.includes('### ❌ Image Tracker — Resolution Failure Diagnostics'),
      'summary must include diagnostic failure section'
    );
    assert.ok(
      summaryContent.includes('#### 📋 Candidate Commits Inspected'),
      'summary must include candidate commits table'
    );
    assert.ok(
      summaryContent.includes('#### 🔍 Candidate Tags Probed'),
      'summary must include probed tags table'
    );
    assert.ok(
      summaryContent.includes('#### 💡 Targeted Guidance'),
      'summary must include targeted guidance'
    );
  } finally {
    global.fetch = origFetch;
    process.exit = origExit;
    process.chdir(cwd);
    restoreEnv(saved);
    fs.rmSync(repoDir, { recursive: true, force: true });
  }
});

test('runMain defaults max_depth to 1 when unset and does not walk to an ancestor image', async () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const os = require('node:os');
  const { runMain } = require('../index.js');
  const origFetch = global.fetch;
  const origExit = process.exit;
  const saved = snapshotEnv();
  const cwd = process.cwd();

  const repoDir = fs.mkdtempSync(path.join(os.tmpdir(), 'default-depth-test-'));
  try {
    process.exit = (code) => {
      throw new Error(`process.exit called with code ${code}`);
    };
    process.chdir(repoDir);
    execFileSync('git', ['init', '-b', 'main'], { encoding: 'utf8' });
    execFileSync('git', ['config', 'user.name', 'test'], { encoding: 'utf8' });
    execFileSync('git', ['config', 'user.email', 'test@example.com'], { encoding: 'utf8' });
    execFileSync('git', ['remote', 'add', 'origin', 'https://github.com/bcgov/nr-hydrometric-rating-curve.git'], { encoding: 'utf8' });

    fs.writeFileSync(path.join(repoDir, 'file.txt'), 'base');
    execFileSync('git', ['add', '.'], { encoding: 'utf8' });
    execFileSync('git', ['commit', '-m', 'initial commit'], { encoding: 'utf8' });

    // Commit 1: squash merge commit of PR #500
    fs.writeFileSync(path.join(repoDir, 'file.txt'), 'feature');
    execFileSync('git', ['add', '.'], { encoding: 'utf8' });
    execFileSync('git', ['commit', '-m', 'feat: cool feature (#500)'], { encoding: 'utf8' });
    const squashSha = execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();

    execFileSync('git', ['commit', '--allow-empty', '-m', 'docs: no image'], { encoding: 'utf8' });
    const headCommit = execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();

    const prHeadSha = '5555555555555555555555555555555555555555';
    const syntheticMergeSha = '6666666666666666666666666666666666666666';
    const expectedDigest = 'sha256:5555555555555555555555555555555555555555555555555555555555555555';

    global.fetch = async (url) => {
      if (url.includes(`/commits/${squashSha}/pulls`)) {
        return {
          ok: true,
          status: 200,
          json: async () => [
            {
              number: 500,
              head: { sha: prHeadSha },
              merge_commit_sha: squashSha,
              title: 'feat: cool feature'
            }
          ]
        };
      }
      if (url.includes(`/commits/${syntheticMergeSha}`)) {
        return {
          ok: true,
          status: 200,
          json: async () => ({
            sha: syntheticMergeSha,
            parents: [{ sha: 'base-sha' }, { sha: prHeadSha }],
            commit: { message: `Merge ${prHeadSha} into base-sha` }
          })
        };
      }
      if (url.endsWith('/manifests/latest')) {
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
      if (url.includes('/token?')) {
        return {
          ok: true,
          status: 200,
          headers: { get: () => null },
          json: async () => ({ token: 'mock-token' })
        };
      }
      if (url.includes('/manifests/pr-500')) {
        return {
          ok: true,
          status: 200,
          headers: {
            get: (h) => (h.toLowerCase() === 'docker-content-digest' ? expectedDigest : null)
          },
          json: async () => ({
            schemaVersion: 2,
            mediaType: 'application/vnd.oci.image.manifest.v1+json',
            digest: expectedDigest,
            annotations: {
              'org.opencontainers.image.revision': syntheticMergeSha,
              'org.opencontainers.image.version': 'pr-500',
              'org.opencontainers.image.source': 'https://github.com/bcgov/nr-hydrometric-rating-curve'
            }
          })
        };
      }
      return { ok: false, status: 404, headers: { get: () => null }, json: async () => ({}) };
    };

    const out = path.join(repoDir, 'github_output');
    delete process.env.GITHUB_EVENT_PATH;
    process.env.GITHUB_ACTIONS = 'true';
    process.env.GITHUB_STEP_SUMMARY = path.join(repoDir, 'step_summary.md');
    process.env.GITHUB_REPOSITORY = 'bcgov/nr-hydrometric-rating-curve';
    process.env.GITHUB_OUTPUT = out;
    process.env.GITHUB_EVENT_NAME = 'push';
    process.env.GITHUB_REF = 'refs/heads/main';
    process.env.GITHUB_SHA = headCommit;
    process.env.INPUT_PACKAGE = 'frontend';
    process.env.PACKAGE = 'frontend';
    process.env.INPUT_REPOSITORY = 'bcgov/nr-hydrometric-rating-curve';
    process.env.REPOSITORY = 'bcgov/nr-hydrometric-rating-curve';
    process.env.INPUT_REVISION = headCommit;
    process.env.REVISION = headCommit;
    delete process.env.MAX_DEPTH;
    delete process.env.INPUT_MAX_DEPTH;
    process.env.DIR = repoDir;
    process.env.INPUT_DIR = repoDir;
    process.env.INPUT_TOKEN = 'mock-token';

    await assert.rejects(() => runMain(), /process\.exit called with code 1/);
    const outputContent = fs.readFileSync(out, 'utf8');
    assert.doesNotMatch(outputContent, new RegExp(expectedDigest), 'must not resolve ancestor squash image at default max_depth 1');
  } finally {
    global.fetch = origFetch;
    process.exit = origExit;
    process.chdir(cwd);
    restoreEnv(saved);
    fs.rmSync(repoDir, { recursive: true, force: true });
  }
});

test('action.yml defines max_depth default of 1', () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const actionYaml = fs.readFileSync(path.join(__dirname, '..', 'action.yml'), 'utf8');
  assert.match(actionYaml, /max_depth:[\s\S]*?default:\s*['"]?1['"]?/, 'action.yml must default max_depth to 1');
});







