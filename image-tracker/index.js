#!/usr/bin/env node

const { execSync, execFileSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const process = require('node:process');

// ---- Logging Helpers -------------------------------------------------------
function logError(msg) {
  if (process.env.GITHUB_ACTIONS === 'true') {
    console.log(`::error::${msg}`);
  } else {
    console.error(`\x1b[31m[ERROR]\x1b[0m ${msg}`);
  }
}

function logWarn(msg) {
  if (process.env.GITHUB_ACTIONS === 'true') {
    console.log(`::warning::${msg}`);
  } else {
    console.error(`\x1b[33m[WARN]\x1b[0m ${msg}`);
  }
}

function logInfo(msg) {
  console.error(`  [i] ${msg}`);
}

function logDebug(msg, debug) {
  if (debug === 'true' || debug === true) {
    console.error(`      [d]   ${msg}`);
  }
}

function logGroup(title) {
  if (process.env.GITHUB_ACTIONS === 'true') {
    console.log(`::group::${title}`);
  } else {
    console.error(`\n\x1b[1m--- ${title} ---\x1b[0m`);
  }
}

function logEndGroup() {
  if (process.env.GITHUB_ACTIONS === 'true') {
    console.log('::endgroup::');
  }
}

const ACTIONS_FORK_DOCS_URL =
  'https://github.com/bcgov/actions/blob/main/README.md#fork-pull-requests';

// ---- Repository resolution (mirrors builder-ghcr publish_repository) ---------
function normalizeRepo(repo) {
  return (repo || '').trim().toLowerCase();
}

function isForkPr(ghRepo, headRepo) {
  const gh = normalizeRepo(ghRepo);
  const head = normalizeRepo(headRepo);
  return head.length > 0 && head !== gh;
}

function publishRepository(eventName, ghRepo, headRepo) {
  if (eventName === 'pull_request' && isForkPr(ghRepo, headRepo)) {
    return normalizeRepo(headRepo);
  }
  return normalizeRepo(ghRepo);
}

function readGithubEvent() {
  const eventPath = process.env.GITHUB_EVENT_PATH;
  if (!eventPath || !fs.existsSync(eventPath)) {
    return {};
  }
  try {
    return JSON.parse(fs.readFileSync(eventPath, 'utf8'));
  } catch {
    return {};
  }
}

function headRepositoryFromEvent(event) {
  return event?.pull_request?.head?.repo?.full_name || '';
}

// Explicit repository input overrides; otherwise match builder-ghcr publish targets.
function resolveImageRepository({
  inputRepository,
  ghRepository,
  eventName,
  headRepository,
  fallbackRepository
}) {
  const input = normalizeRepo(inputRepository);
  const gh = normalizeRepo(ghRepository);
  const fallback = normalizeRepo(fallbackRepository);

  if (input && gh && input !== gh) {
    return input;
  }
  if (gh) {
    return publishRepository(eventName, gh, headRepository);
  }
  return input || fallback;
}

// Fork pull_request often has no GHCR image yet — miss is expected, not fatal.
function imageResolveMissIsExpected(eventName, ghRepo, headRepo) {
  return eventName === 'pull_request' && isForkPr(ghRepo, headRepo);
}

// ---- Package Mapping -------------------------------------------------------
function mapPackages(packageInput, repository) {
  const imagePaths = {};
  const pkgOrder = [];
  if (!packageInput || typeof packageInput !== 'string') {
    return { imagePaths, pkgOrder };
  }

  const repositoryParts = repository ? repository.split('/') : [];
  const repoName = repositoryParts.length > 1 ? repositoryParts[1] : repository;
  const lcRepo = repository ? repository.toLowerCase() : '';

  // Split by commas, whitespace, and newlines
  const rawTokens = packageInput.split(/[\s,]+/);
  for (let token of rawTokens) {
    token = token.trim();
    if (!token) continue;
    if (repoName && token.toLowerCase() === repoName.toLowerCase()) {
      imagePaths[token] = lcRepo;
    } else {
      imagePaths[token] = `${lcRepo}/${token.toLowerCase()}`;
    }
    pkgOrder.push(token);
  }

  return { imagePaths, pkgOrder };
}

// ---- Www-Authenticate Header Parser -----------------------------------------
function parseAuthHeader(header) {
  if (!header || typeof header !== 'string') {
    return { realm: '', service: '' };
  }

  let realm = '';
  let service = '';

  const realmQMatch = header.match(/[Rr][Ee][Aa][Ll][Mm]="([^"]+)"/);
  const realmUQMatch = header.match(/[Rr][Ee][Aa][Ll][Mm]=([^, \t]+)/);
  if (realmQMatch) {
    realm = realmQMatch[1];
  } else if (realmUQMatch) {
    realm = realmUQMatch[1];
  }

  const serviceQMatch = header.match(/[Ss][Ee][Rr][Vv][Ii][Cc][Ee]="([^"]+)"/);
  const serviceUQMatch = header.match(/[Ss][Ee][Rr][Vv][Ii][Cc][Ee]=([^, \t]+)/);
  if (serviceQMatch) {
    service = serviceQMatch[1];
  } else if (serviceUQMatch) {
    service = serviceUQMatch[1];
  }

  // Fallback for header without explicit realm= (e.g. Basic realm="foo")
  if (!realm && header.toLowerCase().includes('basic')) {
    const basicMatch = header.match(/realm="?([^", \t]+)"?/i);
    if (basicMatch) {
      realm = basicMatch[1];
    }
  }

  return { realm, service };
}

// ---- Registry Bearer Token Acquisition --------------------------------------
async function registryToken(repo, registry = 'ghcr.io', token = '') {
  const probeUrl = `https://${registry}/v2/${repo}/manifests/latest`;
  try {
    const res = await fetch(probeUrl, { method: 'GET' });
    if (res.ok || (res.status >= 200 && res.status < 300)) {
      return '__NO_AUTH__';
    }

    let authHeader = res.headers.get('www-authenticate') || '';
    if (!authHeader.toLowerCase().includes('bearer')) {
      // Fallback challenge probe to /v2/
      try {
        const v2Res = await fetch(`https://${registry}/v2/`, { method: 'GET' });
        authHeader = v2Res.headers.get('www-authenticate') || authHeader;
      } catch (err) {
        // Ignore fallback fetch failure
      }
    }

    if (!authHeader || !authHeader.toLowerCase().includes('bearer')) {
      if (!token) {
        return '__NO_AUTH__';
      }
      return null;
    }

    const { realm, service } = parseAuthHeader(authHeader);
    if (!realm) {
      return null;
    }

    const sep = realm.includes('?') ? '&' : '?';
    let params = `scope=repository:${repo}:pull`;
    if (service) {
      params = `service=${service}&${params}`;
    }
    const tokenUrl = `${realm}${sep}${params}`;

    const headers = {};
    if (token) {
      headers['Authorization'] = `Basic ${Buffer.from(`x:${token}`).toString('base64')}`;
    }

    const tokenRes = await fetch(tokenUrl, { headers });
    if (!tokenRes.ok) {
      return null;
    }
    const data = await tokenRes.json();
    const bearer = data.token || data.access_token;
    return bearer || null;
  } catch (err) {
    return null;
  }
}

// ---- Candidate Matching ----------------------------------------------------
function matchesCandidate(revision, tag = '', candidates = [], prMap = {}, prNumMap = {}) {
  if (!revision && !tag) return false;

  for (const cand of candidates) {
    // 1. Direct SHA match
    if (revision && (cand.startsWith(revision) || revision.startsWith(cand))) {
      return true;
    }

    // 2. PR Head match
    const ph = prMap[cand];
    if (ph && revision && (ph.startsWith(revision) || revision.startsWith(ph))) {
      return true;
    }

    // 3. PR Number match
    const pn = prNumMap[cand];
    if (pn !== undefined && pn !== null && pn !== '') {
      if (revision && revision === `pr-${pn}`) {
        return true;
      }
      if (tag && (tag === `pr-${pn}` || tag === String(pn))) {
        return true;
      }
    }
  }

  return false;
}

// ---- Tag Probing -----------------------------------------------------------
async function probeTag(
  imagePath,
  tag,
  bearer,
  registry = 'ghcr.io',
  candidates = [],
  prMap = {},
  prNumMap = {},
  prTitleMap = {},
  digestPrMap = {},
  debug = false
) {
  const base = `https://${registry}/v2/${imagePath}`;
  const accept =
    'application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, */*';
  const headers = { Accept: accept };
  if (bearer && bearer !== '__NO_AUTH__') {
    headers['Authorization'] = `Bearer ${bearer}`;
  }

  try {
    const res = await fetch(`${base}/manifests/${tag}`, { headers });
    if (!res.ok) return null;

    const mdigest = res.headers.get('docker-content-digest') || '';
    const body = await res.json();
    let finalDigest = mdigest || body.digest || '';

    if (!finalDigest) return null;

    const mtype = body.mediaType || '';
    let revision = body.annotations?.['org.opencontainers.image.revision'] || '';
    let created = body.annotations?.['org.opencontainers.image.created'] || '';

    // Multi-arch Index Navigation
    if (mtype.includes('index') || mtype.includes('manifest.list')) {
      const manifests = body.manifests || [];
      const amd64 = manifests.find(
        (m) => m.platform?.architecture === 'amd64' && (m.platform?.os || '') !== 'unknown'
      );
      const childDigest = amd64?.digest || manifests[0]?.digest;

      if (childDigest) {
        const acceptManifest =
          'application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json';
        const childRes = await fetch(`${base}/manifests/${childDigest}`, {
          headers: { ...headers, Accept: acceptManifest }
        });
        if (childRes.ok) {
          const childBody = await childRes.json();
          if (!revision) {
            revision = childBody.annotations?.['org.opencontainers.image.revision'] || '';
          }
          if (!created) {
            created = childBody.annotations?.['org.opencontainers.image.created'] || '';
          }
          if (!revision) {
            const childConfigDigest = childBody.config?.digest;
            if (childConfigDigest) {
              const childBlobRes = await fetch(`${base}/blobs/${childConfigDigest}`, { headers });
              if (childBlobRes.ok) {
                const childConfigObj = await childBlobRes.json();
                revision = childConfigObj.config?.Labels?.['org.opencontainers.image.revision'] || '';
                if (!created) {
                  created = childConfigObj.config?.Labels?.['org.opencontainers.image.created'] || '';
                }
              }
            }
          }
        }
      }
    }

    // Config Blob Fallback
    if (!revision) {
      const configDigest = body.config?.digest;
      if (configDigest) {
        const blobRes = await fetch(`${base}/blobs/${configDigest}`, { headers });
        if (blobRes.ok) {
          const configObj = await blobRes.json();
          revision = configObj.config?.Labels?.['org.opencontainers.image.revision'] || '';
          if (!created) {
            created = configObj.config?.Labels?.['org.opencontainers.image.created'] || '';
          }
        }
      }
    }

    const prMatch = tag.match(/^pr-([0-9]+)$/) || tag.match(/^([0-9]+)$/);
    if (prMatch) {
      digestPrMap[finalDigest] = prMatch[1];
    }

    if (matchesCandidate(revision, tag, candidates, prMap, prNumMap)) {
      for (const cand of candidates) {
        const ph = prMap[cand];
        const pn = prNumMap[cand];

        let patternMatch = false;
        if (pn !== undefined && pn !== null && pn !== '' && (tag === `pr-${pn}` || tag === String(pn))) {
          patternMatch = true;
        } else if (tag === `sha-${cand.slice(0, 7)}` || (ph && tag === `sha-${ph.slice(0, 7)}`)) {
          patternMatch = true;
        }

        const revMatch =
          (revision && cand.startsWith(revision)) ||
          (revision && revision.startsWith(cand)) ||
          (ph && revision && (ph.startsWith(revision) || revision.startsWith(ph))) ||
          (pn && revision === `pr-${pn}`);

        if (revMatch || patternMatch) {
          let title = prTitleMap[cand] || '';
          if (!title) {
            try {
              title = execFileSync('git', ['log', '-1', '--format=%s', cand], {
                encoding: 'utf8',
                stdio: ['pipe', 'pipe', 'ignore']
              }).trim();
            } catch (err) {
              title = 'Unknown commit message';
            }
          }

          const displayRef = tag;
          let auditMsg = `[✓] HIT: ${displayRef} (${finalDigest})`;
          if (pn) auditMsg += ` | PR #${pn}`;
          if (title) auditMsg += `: ${title}`;
          if (created) auditMsg += ` | Built: ${created}`;
          logInfo(auditMsg);

          return {
            sha: cand,
            digest: finalDigest,
            created,
            prNum: pn || digestPrMap[finalDigest] || '',
            msg: title
          };
        }
      }
    }

    return null;
  } catch (err) {
    return null;
  }
}

// ---- Iterative Digest Resolution -------------------------------------------
async function resolveDigestIterative({
  imagePath,
  bearer,
  registry = 'ghcr.io',
  maxTags = 500,
  token = '',
  repository = '',
  candidates = [],
  prMap = {},
  prNumMap = {},
  prTitleMap = {},
  digestPrMap = {},
  debug = false
}) {
  const owner = repository.split('/')[0];
  const pkg = imagePath.split('/').slice(1).join('/') || imagePath;
  const pkgEnc = encodeURIComponent(pkg);

  let rawData = null;
  if (registry === 'ghcr.io' && token && owner) {
    const ghHeaders = {
      Authorization: `Bearer ${token}`,
      Accept: 'application/vnd.github+json',
      'User-Agent': 'image-tracker'
    };

    let apiRes = await fetch(
      `https://api.github.com/orgs/${owner}/packages/container/${pkgEnc}/versions?per_page=100`,
      { headers: ghHeaders }
    ).catch(() => null);

    if (!apiRes || !apiRes.ok) {
      apiRes = await fetch(
        `https://api.github.com/users/${owner}/packages/container/${pkgEnc}/versions?per_page=100`,
        { headers: ghHeaders }
      ).catch(() => null);
    }

    if (apiRes && apiRes.ok) {
      rawData = await apiRes.json().catch(() => null);
    }
  }

  let tagsSeen = 0;

  if (Array.isArray(rawData) && rawData.length > 0) {
    for (const item of rawData) {
      const digest = item.name;
      if (!digest) continue;
      tagsSeen++;
      if (tagsSeen > maxTags) return { hit: null, code: 2 };

      const tags = item.metadata?.container?.tags || [];
      let probeRef = digest;
      for (const t of tags) {
        const prM = t.match(/^pr-([0-9]+)$/) || t.match(/^([0-9]+)$/);
        if (prM) {
          digestPrMap[digest] = prM[1];
          probeRef = t;
          break;
        }
      }

      const res = await probeTag(
        imagePath,
        probeRef,
        bearer,
        registry,
        candidates,
        prMap,
        prNumMap,
        prTitleMap,
        digestPrMap,
        debug
      );
      if (res) return { hit: res, code: 0 };
    }
  } else {
    // Standard OCI /v2/<name>/tags/list
    const base = `https://${registry}/v2/${imagePath}`;
    const headers = {};
    if (bearer && bearer !== '__NO_AUTH__') {
      headers['Authorization'] = `Bearer ${bearer}`;
    }

    const tagsRes = await fetch(`${base}/tags/list`, { headers }).catch(() => null);
    if (tagsRes && tagsRes.ok) {
      const body = await tagsRes.json().catch(() => ({}));
      const tagList = body.tags || [];
      for (const tag of tagList) {
        if (!tag) continue;
        tagsSeen++;
        if (tagsSeen > maxTags) return { hit: null, code: 2 };

        const res = await probeTag(
          imagePath,
          tag,
          bearer,
          registry,
          candidates,
          prMap,
          prNumMap,
          prTitleMap,
          digestPrMap,
          debug
        );
        if (res) return { hit: res, code: 0 };
      }
    }
  }

  return { hit: null, code: 1 };
}

// ---- Step Summary Renderer ------------------------------------------------
function renderStepSummary({
  registry = 'ghcr.io',
  revision = 'HEAD',
  pivotSha = '',
  candidates = [],
  pkgOrder = [],
  imagePaths = {},
  images = {}
}) {
  const revisionDisplay = revision.replace(/\\/g, '\\\\').replace(/\|/g, '\\|');
  let targetStr = '';
  if (pivotSha && (revision.startsWith(pivotSha.slice(0, 7)) || pivotSha.startsWith(revision))) {
    targetStr = `\`${pivotSha.slice(0, 7)}\``;
  } else if (pivotSha) {
    targetStr = `\`${pivotSha.slice(0, 7)}\` (${revisionDisplay})`;
  } else {
    targetStr = `\`${revisionDisplay}\``;
  }

  const lines = [
    '### 📦 Image Tracker',
    '',
    '| Package | Target Commit | Resolved Commit | Search Depth | Image Reference / Digest |',
    '| :--- | :--- | :--- | :--- | :--- |'
  ];

  for (const pkg of pkgOrder) {
    const pkgDisplay = pkg.replace(/\\/g, '\\\\').replace(/\|/g, '\\|');
    const hitObj = images[pkg];
    const path = imagePaths[pkg] || '';

    if (hitObj) {
      const sha = hitObj.sha || '';
      const digest = hitObj.digest || '';
      const ref = `${registry}/${path}@${digest}`;
      const resolvedStr = `\`${sha.slice(0, 7)}\``;

      let depth = 0;
      for (let i = 0; i < candidates.length; i++) {
        if (candidates[i].startsWith(sha) || sha.startsWith(candidates[i])) {
          depth = i + 1;
          break;
        }
      }

      let depthStr = '—';
      if (depth === 1) {
        depthStr = '1';
      } else if (depth > 1) {
        depthStr = `${depth} (walked)`;
      }

      lines.push(`| \`${pkgDisplay}\` | ${targetStr} | ${resolvedStr} | ${depthStr} | \`${ref}\` |`);
    } else {
      lines.push(`| \`${pkgDisplay}\` | ${targetStr} | — | — | *Not resolved* |`);
    }
  }

  lines.push('');
  return lines.join('\n');
}

// ---- Helper to Extract PR Number from Payload / Object --------------------
function extractPrNumber(payload) {
  if (!payload) return '';
  if (typeof payload === 'object') {
    const pr = payload.prNum || payload.pr;
    return pr && pr !== 'null' ? String(pr) : '';
  }
  if (typeof payload === 'string') {
    const parts = payload.split('|');
    if (parts.length >= 4) {
      const pPr = parts[3];
      return pPr && pPr !== 'null' ? pPr : '';
    }
  }
  return '';
}

// ---- Main Function ---------------------------------------------------------
async function runMain() {
  const env = process.env;
  const args = process.argv.slice(2);
  const ghRepository = env.GITHUB_REPOSITORY || '';
  const eventName = env.GITHUB_EVENT_NAME || '';
  const event = readGithubEvent();
  const headRepository = headRepositoryFromEvent(event);

  // 1. Repository
  const rawInput = (env.REPOSITORY || env.INPUT_REPOSITORY || '').trim();
  let fallbackRepository = rawInput || ghRepository;
  if (!fallbackRepository) {
    try {
      const remoteUrl = execFileSync('git', ['remote', 'get-url', 'origin'], {
        encoding: 'utf8',
        stdio: ['pipe', 'pipe', 'ignore']
      }).trim();
      const match = remoteUrl.match(/github\.com[:/]([^/]+\/[^/.]+)/);
      if (match) fallbackRepository = match[1];
    } catch (err) {}
  }

  let repository = resolveImageRepository({
    inputRepository: rawInput || ghRepository,
    ghRepository,
    eventName,
    headRepository,
    fallbackRepository
  });

  // 2. Package Input
  let packageInput = '';
  if (args.length > 0) {
    packageInput = args.join(',');
  } else {
    packageInput = env.PACKAGE || env.INPUT_PACKAGE || '';
  }

  // 3. Settings
  let registry = env.REGISTRY || env.INPUT_REGISTRY || 'ghcr.io';
  registry = registry.replace(/^https?:\/\//, '').replace(/\/$/, '') || 'ghcr.io';

  const revision = env.REVISION || env.INPUT_REVISION || 'HEAD';
  const dir = env.DIR || env.INPUT_DIR || '.';
  const token = env.TOKEN || env.INPUT_TOKEN || env.INPUT_GITHUB_TOKEN || env.GITHUB_TOKEN || env.GH_TOKEN || '';
  const maxTagsStr = env.MAX_TAGS || env.INPUT_MAX_TAGS || '500';
  const maxDepthStr = env.MAX_DEPTH || env.INPUT_MAX_DEPTH || '1';
  const debug = env.DEBUG || env.INPUT_DEBUG || 'false';

  if (!/^\d+$/.test(maxTagsStr) || parseInt(maxTagsStr, 10) <= 0) {
    logError('MAX_TAGS must be a positive integer.');
    process.exit(1);
  }
  if (!/^\d+$/.test(maxDepthStr) || parseInt(maxDepthStr, 10) <= 0) {
    logError('MAX_DEPTH must be a positive integer.');
    process.exit(1);
  }
  const maxTags = parseInt(maxTagsStr, 10);
  const maxDepth = parseInt(maxDepthStr, 10);

  if (!packageInput) {
    logError('Missing required package names. Usage: node index.js pkg1 [pkg2 ...]');
    process.exit(1);
  }
  if (!repository) {
    logError('No repository detected. Set REPOSITORY or run from a git repo.');
    process.exit(1);
  }
  if (!fs.existsSync(dir) || !fs.statSync(dir).isDirectory()) {
    logError(`Invalid directory '${dir}'.`);
    process.exit(1);
  }

  process.chdir(dir);

  // ---- State -----------------------------------------------------------------
  const prMap = {};
  const prNumMap = {};
  const prTitleMap = {};
  const candidateMap = {};
  const images = {};
  const digestPrMap = {};
  const missing = [];

  // ---- Git Ancestry Resolution -----------------------------------------------
  let pivotSha = '';
  try {
    pivotSha = execFileSync('git', ['rev-parse', '--verify', '--quiet', `${revision}^{commit}`], {
      encoding: 'utf8',
      stdio: ['pipe', 'pipe', 'ignore']
    }).trim();
  } catch (err) {}

  if (!pivotSha && /^[0-9a-f]{7,40}$/i.test(revision) && token) {
    logInfo(`Revision ${revision} not found locally. Checking for PR metadata...`);
    try {
      const ghHeaders = {
        Authorization: `Bearer ${token}`,
        Accept: 'application/vnd.github+json',
        'User-Agent': 'image-tracker'
      };
      const prRes = await fetch(`https://api.github.com/repos/${repository}/commits/${revision}/pulls`, {
        headers: ghHeaders
      });
      if (prRes.ok) {
        const prData = await prRes.json();
        if (Array.isArray(prData) && prData.length > 0) {
          const pr = prData[0];
          const headSha = pr.head?.sha;
          const prNum = pr.number;
          const prTitle = pr.title;

          logInfo(`Revision matches PR #${prNum}. Fetching ref...`);
          try {
            execFileSync('git', ['fetch', 'origin', `pull/${prNum}/head:refs/remotes/origin/pr/${prNum}`, '--quiet'], {
              stdio: 'ignore'
            });
            pivotSha = execFileSync('git', ['rev-parse', '--verify', '--quiet', `${revision}^{commit}`], {
              encoding: 'utf8',
              stdio: ['pipe', 'pipe', 'ignore']
            }).trim();
            if (pivotSha) {
              prTitleMap[pivotSha] = prTitle;
              if (headSha) prTitleMap[headSha] = prTitle;
            }
          } catch (fetchErr) {}
        }
      }
    } catch (err) {}
  }

  if (!pivotSha) {
    logError(`Could not resolve git revision '${revision}'.`);
    process.exit(1);
  }

  let candidates = [];
  try {
    const revListOut = execFileSync('git', ['rev-list', '--topo-order', '-n', String(maxDepth), '--', pivotSha], {
      encoding: 'utf8',
      stdio: ['pipe', 'pipe', 'ignore']
    }).trim();
    candidates = revListOut.split(/\r?\n/).filter(Boolean);
  } catch (err) {
    candidates = [pivotSha];
  }

  for (const sha of candidates) {
    candidateMap[sha] = true;
    let msg = '';
    try {
      msg = execFileSync('git', ['log', '-1', '--format=%s', sha], {
        encoding: 'utf8',
        stdio: ['pipe', 'pipe', 'ignore']
      }).trim();
    } catch (err) {}

    const prFromMsg = msg.match(/\(#([0-9]+)\)/);
    if (prFromMsg) {
      logDebug(`Mapped ${sha.slice(0, 7)} to PR #${prFromMsg[1]} (from msg)`, debug);
      prNumMap[sha] = prFromMsg[1];
    }

    if (token) {
      try {
        const apiShas = [sha];
        try {
          const parents = execFileSync('git', ['log', '-1', '--format=%P', sha], {
            encoding: 'utf8',
            stdio: ['pipe', 'pipe', 'ignore']
          })
            .trim()
            .split(/\s+/);
          if (parents.length >= 2) {
            apiShas.push(parents[1]);
          }
        } catch (pErr) {}

        const ghHeaders = {
          Authorization: `Bearer ${token}`,
          Accept: 'application/vnd.github+json',
          'User-Agent': 'image-tracker'
        };

        for (const checkSha of apiShas) {
          const prRes = await fetch(`https://api.github.com/repos/${repository}/commits/${checkSha}/pulls`, {
            headers: ghHeaders
          }).catch(() => null);

          if (prRes && prRes.ok) {
            const prs = await prRes.json().catch(() => []);
            if (Array.isArray(prs) && prs.length > 0) {
              const pr = prs[0];
              const headSha = pr.head?.sha;
              const prNumApi = pr.number;
              const prTitle = pr.title;

              if (prNumApi) {
                logDebug(`Mapped ${sha.slice(0, 7)} to PR #${prNumApi} (from API)`, debug);
                prNumMap[sha] = String(prNumApi);
                prTitleMap[sha] = prTitle;
                if (headSha) {
                  prMap[sha] = headSha;
                  prNumMap[headSha] = String(prNumApi);
                  prTitleMap[headSha] = prTitle;
                }
                break;
              }
            }
          }
        }
      } catch (err) {}
    }
  }

  const { imagePaths, pkgOrder } = mapPackages(packageInput, repository);
  if (pkgOrder.length === 0) {
    logError('PACKAGE_INPUT did not contain any valid package names.');
    process.exit(1);
  }

  // ---- Execution -------------------------------------------------------------
  logGroup(`Image Tracker — resolving ancestry for ${revision}`);
  logInfo(`Registry: ${registry}`);
  logInfo(`Repository: ${repository}`);
  logInfo(`Starting SHA: ${pivotSha}`);

  const imagesJson = {};

  for (const pkg of pkgOrder) {
    const path = imagePaths[pkg];
    const bearer = await registryToken(path, registry, token);
    if (!bearer) {
      logError(`Failed to obtain registry token for ${path}.`);
      missing.push(pkg);
      continue;
    }

    let res = null;
    // 1. Forensic Trace
    for (const candidate of candidates) {
      const prHead = prMap[candidate];
      const prNum = prNumMap[candidate];

      if (prNum) {
        res = await probeTag(path, `pr-${prNum}`, bearer, registry, candidates, prMap, prNumMap, prTitleMap, digestPrMap, debug);
        if (!res) {
          res = await probeTag(path, String(prNum), bearer, registry, candidates, prMap, prNumMap, prTitleMap, digestPrMap, debug);
        }
      }

      if (!res && prHead) {
        res = await probeTag(path, `sha-${prHead.slice(0, 7)}`, bearer, registry, candidates, prMap, prNumMap, prTitleMap, digestPrMap, debug);
      }

      if (!res) {
        res = await probeTag(path, `sha-${candidate.slice(0, 7)}`, bearer, registry, candidates, prMap, prNumMap, prTitleMap, debug);
      }

      if (res) break;
    }

    if (!res) {
      logInfo('Forensic trace missed; falling back to iterative scan...');
      const iterRes = await resolveDigestIterative({
        imagePath: path,
        bearer,
        registry,
        maxTags,
        token,
        repository,
        candidates,
        prMap,
        prNumMap,
        prTitleMap,
        digestPrMap,
        debug
      });

      if (iterRes.code === 2) {
        logError(`Iterative scan stopped for ${path} because MAX_TAGS (${maxTags}) was exceeded. Increase MAX_TAGS to continue.`);
        process.exit(2);
      }
      res = iterRes.hit;
    }

    if (!res) {
      console.error(`  [x] MISS: ${pkg}`);
      missing.push(pkg);
      continue;
    }

    const ref = `${registry}/${path}@${res.digest}`;
    console.error(`  [✓] HIT: ${pkg} -> ${ref}`);

    images[pkg] = res;
    imagesJson[pkg] = ref;
  }

  logEndGroup();

  const summaryMarkdown = renderStepSummary({
    registry,
    revision,
    pivotSha,
    candidates,
    pkgOrder,
    imagePaths,
    images
  });

  if (env.GITHUB_ACTIONS === 'true') {
    if (env.GITHUB_STEP_SUMMARY) {
      fs.appendFileSync(env.GITHUB_STEP_SUMMARY, summaryMarkdown + '\n');
    }
  }

  if (env.GITHUB_ACTIONS === 'true') {
    if (env.GITHUB_OUTPUT) {
      const outputLines = [];
      outputLines.push(`images=${JSON.stringify(imagesJson)}`);

      const firstPkg = pkgOrder[0];
      let rPr = '';
      if (firstPkg && images[firstPkg]) {
        const firstHit = images[firstPkg];
        const fPath = imagePaths[firstPkg];
        outputLines.push(`image=${registry}/${fPath}@${firstHit.digest}`);
        outputLines.push(`digest=${firstHit.digest}`);
        if (firstHit.prNum && firstHit.prNum !== 'null') {
          rPr = firstHit.prNum;
        }

        const digestsJson = {};
        for (const [k, v] of Object.entries(imagesJson)) {
          const d = v.split('@')[1];
          if (d) digestsJson[k] = d;
        }
        outputLines.push(`digests=${JSON.stringify(digestsJson)}`);
      } else {
        outputLines.push('image=');
        outputLines.push('digest=');
        outputLines.push('digests={}');
      }
      outputLines.push(`pr=${rPr}`);
      fs.appendFileSync(env.GITHUB_OUTPUT, outputLines.join('\n') + '\n');
    }
  } else {
    console.log(`\n--- Results ---\n${JSON.stringify(imagesJson, null, 2)}`);
  }

  if (missing.length > 0) {
    if (imageResolveMissIsExpected(eventName, ghRepository, headRepository)) {
      logWarn(
        `Fork pull_request: no image in ${registry} for ${missing.join(', ')} at ${repository}. ` +
          `Downstream deploy should no-op on an empty digest. ` +
          `Images publish on push to your fork (packages must be public for upstream CI to pull). ` +
          `See ${ACTIONS_FORK_DOCS_URL}`
      );
      return;
    }
    logError(`Failed to resolve: ${missing.join(' ')}`);
    process.exit(1);
  }
}

if (require.main === module) {
  runMain().catch((err) => {
    logError(err.message || String(err));
    process.exit(1);
  });
}

module.exports = {
  mapPackages,
  parseAuthHeader,
  registryToken,
  matchesCandidate,
  probeTag,
  resolveDigestIterative,
  renderStepSummary,
  extractPrNumber,
  isForkPr,
  publishRepository,
  resolveImageRepository,
  imageResolveMissIsExpected,
  headRepositoryFromEvent,
  runMain
};
