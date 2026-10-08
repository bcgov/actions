const test = require('node:test')
const assert = require('node:assert')
const {
  parseInputs,
  packagePaths,
  selectVersions,
  cleanPackage
} = require('../index.js')

const digest = c => `sha256:${c.repeat(64)}`
const sha = c => c.repeat(40)
const version = (id, d, tags = []) => ({
  id,
  name: d,
  metadata: {container: {tags}}
})
const image = () => ({children: [], subject: null})
const index = children => ({children, subject: null})
const referrer = subject => ({children: [], subject})

// Fixture package: closed PRs #10 (head sha a, old push sha b) and #11, open PR #12.
const versions = [
  version(1, digest('1'), ['prod', '10', sha('a')]), // promoted closed-PR image (multi-arch)
  version(2, digest('2')), // child of 1
  version(3, digest('3')), // child of 1
  version(4, digest('4'), ['11', sha('c')]), // closed PR only (multi-arch)
  version(5, digest('5')), // child of 4
  version(6, digest('6'), [sha('b')]), // older push of closed PR #10
  version(7, digest('7'), ['12']), // open PR
  version(8, digest('8'), ['pr-12']), // open PR, docker/metadata style
  version(9, digest('9')), // untagged, unreferenced
  version(10, digest('a'), ['11', sha('d')]), // closed PR #11 tag, but d is a merge SHA
  version(11, digest('b'), ['999']), // numeric tag that is not a PR
  version(12, digest('c'), ['latest']),
  version(13, digest('d')), // referrer of latest
  version(14, digest('e')) // referrer of a deleted image
]
const manifests = new Map([
  [digest('1'), index([digest('2'), digest('3')])],
  [digest('2'), image()],
  [digest('3'), image()],
  [digest('4'), index([digest('5')])],
  [digest('5'), image()],
  [digest('6'), image()],
  [digest('7'), image()],
  [digest('8'), image()],
  [digest('9'), image()],
  [digest('a'), image()],
  [digest('b'), image()],
  [digest('c'), image()],
  [digest('d'), referrer(digest('c'))],
  [digest('e'), referrer(digest('9'))]
])
const openPrs = new Set([12])
const closedPrCommits = new Map([
  [10, new Set([sha('a'), sha('b')])],
  [11, new Set([sha('c')])]
])

function decide(keepDigests = new Set()) {
  const out = selectVersions({
    versions,
    manifests,
    openPrs,
    closedPrCommits,
    keepDigests
  })
  return new Map(out.map(d => [d.id, d]))
}

test('Protected tag sharing a digest with a closed-PR tag is kept', () => {
  const d = decide().get(1)
  assert.strictEqual(d.remove, false)
  assert.strictEqual(d.reason, 'tag prod')
})

test('Multi-arch children of a protected index are kept', () => {
  const out = decide()
  assert.strictEqual(out.get(2).remove, false)
  assert.strictEqual(out.get(3).remove, false)
  assert.strictEqual(out.get(2).reason, `index child of ${digest('1')}`)
})

test('Open PR images are kept, bare and pr-<n> tags', () => {
  const out = decide()
  assert.strictEqual(out.get(7).remove, false)
  assert.strictEqual(out.get(8).remove, false)
  assert.strictEqual(out.get(7).reason, 'open PR #12')
})

test('Closed-PR-only image and its untagged children are deleted', () => {
  const out = decide()
  assert.strictEqual(out.get(4).remove, true)
  assert.strictEqual(out.get(4).reason, 'closed PR only')
  assert.strictEqual(out.get(5).remove, true)
})

test('Older push of a closed PR, tagged only with its commit SHA, is deleted', () => {
  assert.strictEqual(decide().get(6).remove, true)
})

test('Unreferenced untagged versions are deleted', () => {
  const d = decide().get(9)
  assert.strictEqual(d.remove, true)
  assert.strictEqual(d.reason, 'untagged, unreferenced')
})

test('A SHA tag outside the closed PR commits (merge SHA) keeps the image', () => {
  const d = decide().get(10)
  assert.strictEqual(d.remove, false)
  assert.strictEqual(d.reason, `tag ${sha('d')} is not a closed PR commit`)
})

test('A numeric tag that is not a PR is kept', () => {
  assert.strictEqual(decide().get(11).reason, 'tag 999 is not a closed PR')
})

test('Referrers follow their subject', () => {
  const out = decide()
  assert.strictEqual(out.get(13).remove, false)
  assert.strictEqual(out.get(14).remove, true)
})

test('keep_digests protects a closed-PR image and its index children', () => {
  const out = decide(new Set([digest('4')]))
  assert.strictEqual(out.get(4).remove, false)
  assert.strictEqual(out.get(4).reason, 'keep_digests')
  assert.strictEqual(out.get(5).remove, false)
})

test('Exactly the expected versions are selected', () => {
  const ids = [...decide().values()].filter(d => d.remove).map(d => d.id)
  assert.deepStrictEqual(ids, [4, 5, 6, 9, 14])
})

function fakeIo({missingPackage = false, failManifest = false} = {}) {
  const deleted = []
  return {
    deleted,
    async listVersions() {
      return missingPackage ? null : versions
    },
    async prCommits(n) {
      return closedPrCommits.get(n) || null
    },
    async manifest(pkg, d) {
      if (failManifest && d === digest('7')) throw new Error('HTTP 500')
      return manifests.get(d)
    },
    async deleteVersion(pkg, id) {
      deleted.push(id)
      return id === 9 ? 'missing' : 'deleted'
    }
  }
}

test('Dry run selects but deletes nothing', async () => {
  const io = fakeIo()
  const selected = await cleanPackage('backend', {
    io,
    dryRun: true,
    keepDigests: new Set(),
    openPrs
  })
  assert.deepStrictEqual(
    selected.map(d => d.id),
    [4, 5, 6, 9, 14]
  )
  assert.deepStrictEqual(io.deleted, [])
})

test('Apply deletes exactly the selected versions; a vanished one is a no-op', async () => {
  const io = fakeIo()
  await cleanPackage('backend', {
    io,
    dryRun: false,
    keepDigests: new Set(),
    openPrs
  })
  assert.deepStrictEqual(io.deleted, [4, 5, 6, 9, 14])
})

test('Missing package is a no-op', async () => {
  const io = fakeIo({missingPackage: true})
  const selected = await cleanPackage('nope', {
    io,
    dryRun: false,
    keepDigests: new Set(),
    openPrs
  })
  assert.deepStrictEqual(selected, [])
  assert.deepStrictEqual(io.deleted, [])
})

test('Unresolved protection data fails the package before any delete', async () => {
  const io = fakeIo({failManifest: true})
  await assert.rejects(
    cleanPackage('backend', {
      io,
      dryRun: false,
      keepDigests: new Set(),
      openPrs
    }),
    /HTTP 500/
  )
  assert.deepStrictEqual(io.deleted, [])
})

const env = {
  INPUT_PACKAGES: 'backend, frontend\nmigrations',
  INPUT_DRY_RUN: 'true',
  INPUT_KEEP_DIGESTS: `${digest('1')}\n${digest('2')}`,
  INPUT_TOKEN: 'x',
  GITHUB_REPOSITORY: 'bcgov/quickstart-openshift',
  GITHUB_API_URL: 'https://api.github.com'
}

test('Inputs parse lists and dry_run', () => {
  const inputs = parseInputs(env)
  assert.deepStrictEqual(inputs.packages, ['backend', 'frontend', 'migrations'])
  assert.strictEqual(inputs.dryRun, true)
  assert.strictEqual(inputs.keepDigests.size, 2)
  assert.strictEqual(
    parseInputs({...env, INPUT_DRY_RUN: 'false'}).dryRun,
    false
  )
})

test('Invalid inputs fail fast', () => {
  assert.throws(() => parseInputs({...env, INPUT_PACKAGES: ' '}), /packages/)
  assert.throws(() => parseInputs({...env, INPUT_DRY_RUN: ''}), /dry_run/)
  assert.throws(() => parseInputs({...env, INPUT_DRY_RUN: 'yes'}), /dry_run/)
  assert.throws(
    () => parseInputs({...env, INPUT_KEEP_DIGESTS: 'latest'}),
    /keep_digests/
  )
  assert.throws(() => parseInputs({...env, INPUT_TOKEN: ''}), /token/)
})

test('Package paths follow the image-tracker convention', () => {
  assert.deepStrictEqual(
    packagePaths('Backend', 'bcgov/Quickstart-OpenShift'),
    {
      owner: 'bcgov',
      name: 'quickstart-openshift/backend',
      image: 'bcgov/quickstart-openshift/backend'
    }
  )
  assert.strictEqual(
    packagePaths('vexilon', 'MinionTech/vexilon').name,
    'vexilon'
  )
})
