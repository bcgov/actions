const fs = require('node:fs')
const process = require('node:process')

// Builder tags PR images with the PR number (docker/metadata uses pr-<n>) and the full source SHA.
const PR_TAG = /^(?:pr-)?(\d+)$/
const SHA_TAG = /^[0-9a-f]{40}$/
const DIGEST = /^sha256:[0-9a-f]{64}$/
const MANIFEST_ACCEPT = [
  'application/vnd.oci.image.index.v1+json',
  'application/vnd.docker.distribution.manifest.list.v2+json',
  'application/vnd.oci.image.manifest.v1+json',
  'application/vnd.docker.distribution.manifest.v2+json'
].join(', ')

function splitList(input) {
  return (input || '').split(/[\s,]+/).filter(Boolean)
}

function parseInputs(env) {
  const packages = splitList(env.INPUT_PACKAGES)
  if (packages.length === 0) {
    throw new Error("Input 'packages' is required.")
  }
  const dryRun = (env.INPUT_DRY_RUN || '').trim()
  if (dryRun !== 'true' && dryRun !== 'false') {
    throw new Error(
      `Input 'dry_run' must be 'true' or 'false', got '${dryRun}'.`
    )
  }
  const keepDigests = splitList(env.INPUT_KEEP_DIGESTS)
  for (const digest of keepDigests) {
    if (!DIGEST.test(digest)) {
      throw new Error(
        `Input 'keep_digests' holds '${digest}', expected sha256:<64 hex>.`
      )
    }
  }
  const token = (env.INPUT_TOKEN || '').trim()
  if (!token) {
    throw new Error("Input 'token' is empty.")
  }
  const repository = env.GITHUB_REPOSITORY || ''
  if (!/^[^/\s]+\/[^/\s]+$/.test(repository)) {
    throw new Error('GITHUB_REPOSITORY is not set to <owner>/<repo>.')
  }
  if (!env.GITHUB_API_URL) {
    throw new Error('GITHUB_API_URL is not set.')
  }
  return {
    packages,
    dryRun: dryRun === 'true',
    keepDigests: new Set(keepDigests),
    token,
    repository,
    apiUrl: env.GITHUB_API_URL
  }
}

// Same convention as image-tracker mapPackages.
function packagePaths(pkg, repository) {
  const [owner, repo] = repository.toLowerCase().split('/')
  const lower = pkg.toLowerCase()
  const name = lower === repo ? repo : `${repo}/${lower}`
  return {owner, name, image: `${owner}/${name}`}
}

function tagsOf(version) {
  return version.metadata?.container?.tags || []
}

// Why a tagged version must stay, or null when every tag belongs to a closed PR.
function tagKeepReason(tags, openPrs, closedPrCommits, closedShas) {
  for (const tag of tags) {
    const pr = PR_TAG.exec(tag)
    if (pr) {
      const n = Number(pr[1])
      if (openPrs.has(n)) return `open PR #${n}`
      if (!closedPrCommits.has(n)) return `tag ${tag} is not a closed PR`
      continue
    }
    if (SHA_TAG.test(tag)) {
      if (!closedShas.has(tag)) return `tag ${tag} is not a closed PR commit`
      continue
    }
    return `tag ${tag}`
  }
  return null
}

/**
 * Decide keep/delete for every version of one package.
 * @param {object} p
 * @param {{id: number, name: string, metadata?: object}[]} p.versions API versions; name is the digest
 * @param {Map<string, {children: string[], subject: string|null}>} p.manifests by digest
 * @param {Set<number>} p.openPrs
 * @param {Map<number, Set<string>>} p.closedPrCommits closed PR number -> commit SHAs
 * @param {Set<string>} p.keepDigests
 */
function selectVersions({
  versions,
  manifests,
  openPrs,
  closedPrCommits,
  keepDigests
}) {
  const closedShas = new Set(
    [...closedPrCommits.values()].flatMap(shas => [...shas])
  )
  const kept = new Map()
  for (const digest of keepDigests) kept.set(digest, 'keep_digests')
  for (const v of versions) {
    const tags = tagsOf(v)
    if (tags.length === 0 || kept.has(v.name)) continue
    const reason = tagKeepReason(tags, openPrs, closedPrCommits, closedShas)
    if (reason) kept.set(v.name, reason)
  }

  // Index children of kept versions, and referrers (subject) of kept images, stay too.
  let grew = true
  while (grew) {
    grew = false
    for (const v of versions) {
      const refs = manifests.get(v.name)
      if (!refs) throw new Error(`No manifest data for ${v.name}.`)
      if (kept.has(v.name)) {
        for (const child of refs.children) {
          if (!kept.has(child)) {
            kept.set(child, `index child of ${v.name}`)
            grew = true
          }
        }
      } else if (refs.subject && kept.has(refs.subject)) {
        kept.set(v.name, `referrer of ${refs.subject}`)
        grew = true
      }
    }
  }

  return versions.map(v => {
    const tags = tagsOf(v)
    const reason = kept.get(v.name)
    return {
      id: v.id,
      digest: v.name,
      tags,
      remove: !reason,
      reason:
        reason || (tags.length ? 'closed PR only' : 'untagged, unreferenced')
    }
  })
}

async function cleanPackage(pkg, {io, dryRun, keepDigests, openPrs}) {
  const versions = await io.listVersions(pkg)
  if (versions === null) {
    console.log(`${pkg}: package not found, nothing to do`)
    return []
  }

  const numbers = new Set()
  for (const v of versions) {
    for (const tag of tagsOf(v)) {
      const pr = PR_TAG.exec(tag)
      if (pr && !openPrs.has(Number(pr[1]))) numbers.add(Number(pr[1]))
    }
  }
  const closedPrCommits = new Map()
  for (const n of numbers) {
    const shas = await io.prCommits(n)
    if (shas) closedPrCommits.set(n, shas)
  }

  const manifests = new Map()
  for (let i = 0; i < versions.length; i += 10) {
    const batch = versions.slice(i, i + 10)
    const refs = await Promise.all(batch.map(v => io.manifest(pkg, v.name)))
    batch.forEach((v, j) => manifests.set(v.name, refs[j]))
  }

  const decisions = selectVersions({
    versions,
    manifests,
    openPrs,
    closedPrCommits,
    keepDigests
  })
  const verb = dryRun ? 'would delete' : 'delete'
  for (const d of decisions) {
    const action = d.remove ? verb : 'keep'
    console.log(
      `${pkg} ${d.id} ${d.digest} [${d.tags.join(', ')}] ${action} (${d.reason})`
    )
  }

  const selected = decisions.filter(d => d.remove)
  if (dryRun) return selected

  let failed = 0
  for (const d of selected) {
    try {
      const result = await io.deleteVersion(pkg, d.id)
      console.log(
        result === 'missing'
          ? `${pkg} ${d.id}: already gone, nothing to delete`
          : `${pkg} ${d.id}: deleted`
      )
    } catch (err) {
      failed++
      console.log(`::error::${pkg} ${d.id}: ${err.message}`)
    }
  }
  if (failed) throw new Error(`${failed} deletion(s) failed`)
  return selected
}

function liveIo({apiUrl, repository, token}) {
  const headers = {
    Authorization: `Bearer ${token}`,
    Accept: 'application/vnd.github+json'
  }
  const [owner] = repository.split('/')
  let packagesBase
  const bearers = new Map()

  async function getAll(path) {
    const items = []
    const sep = path.includes('?') ? '&' : '?'
    for (let page = 1; ; page++) {
      const res = await fetch(
        `${apiUrl}${path}${sep}per_page=100&page=${page}`,
        {headers}
      )
      if (res.status === 404 && page === 1) return null
      if (!res.ok) throw new Error(`GET ${path}: HTTP ${res.status}`)
      const batch = await res.json()
      items.push(...batch)
      if (batch.length < 100) return items
    }
  }

  async function base() {
    if (!packagesBase) {
      const res = await fetch(`${apiUrl}/users/${owner}`, {headers})
      if (!res.ok) throw new Error(`GET /users/${owner}: HTTP ${res.status}`)
      const {type} = await res.json()
      packagesBase =
        type === 'Organization' ? `/orgs/${owner}` : `/users/${owner}`
    }
    return packagesBase
  }

  function versionsPath(prefix, pkg) {
    const {name} = packagePaths(pkg, repository)
    return `${prefix}/packages/container/${encodeURIComponent(name)}/versions`
  }

  async function bearer(image) {
    if (!bearers.has(image)) {
      const basic = Buffer.from(`x:${token}`).toString('base64')
      const res = await fetch(
        `https://ghcr.io/token?service=ghcr.io&scope=repository:${image}:pull`,
        {headers: {Authorization: `Basic ${basic}`}}
      )
      if (!res.ok) {
        throw new Error(`GHCR token for ${image}: HTTP ${res.status}`)
      }
      bearers.set(image, (await res.json()).token)
    }
    return bearers.get(image)
  }

  return {
    async openPrs() {
      const pulls = await getAll(`/repos/${repository}/pulls?state=open`)
      if (pulls === null) throw new Error(`Repository ${repository} not found`)
      return new Set(pulls.map(p => p.number))
    },
    async prCommits(n) {
      const commits = await getAll(`/repos/${repository}/pulls/${n}/commits`)
      return commits && new Set(commits.map(c => c.sha))
    },
    async listVersions(pkg) {
      return getAll(versionsPath(await base(), pkg))
    },
    async manifest(pkg, digest) {
      const {image} = packagePaths(pkg, repository)
      const res = await fetch(
        `https://ghcr.io/v2/${image}/manifests/${digest}`,
        {
          headers: {
            Authorization: `Bearer ${await bearer(image)}`,
            Accept: MANIFEST_ACCEPT
          }
        }
      )
      if (!res.ok) {
        throw new Error(`manifest ${digest} of ${image}: HTTP ${res.status}`)
      }
      const body = await res.json()
      return {
        children: (body.manifests || []).map(m => m.digest),
        subject: body.subject?.digest || null
      }
    },
    async deleteVersion(pkg, id) {
      const path = `${versionsPath(await base(), pkg)}/${id}`
      const res = await fetch(`${apiUrl}${path}`, {method: 'DELETE', headers})
      if (res.status === 404) return 'missing'
      if (!res.ok) throw new Error(`DELETE ${path}: HTTP ${res.status}`)
      return 'deleted'
    }
  }
}

async function main(env = process.env) {
  const inputs = parseInputs(env)
  const io = liveIo(inputs)
  const openPrs = await io.openPrs()
  console.log(
    inputs.dryRun
      ? 'Dry run: nothing is deleted. Set dry_run: false to delete.'
      : 'dry_run is false: selected versions are deleted.'
  )

  const selected = []
  const failures = []
  for (const pkg of inputs.packages) {
    console.log(`::group::${pkg}`)
    try {
      const picked = await cleanPackage(pkg, {...inputs, io, openPrs})
      for (const d of picked) {
        selected.push({package: pkg, id: d.id, digest: d.digest, tags: d.tags})
      }
    } catch (err) {
      failures.push(pkg)
      console.log(`::error::${pkg}: ${err.message}`)
    }
    console.log('::endgroup::')
  }

  if (env.GITHUB_OUTPUT) {
    fs.appendFileSync(
      env.GITHUB_OUTPUT,
      `selected=${JSON.stringify(selected)}\n`
    )
  }
  console.log(
    `${selected.length} version(s) ${inputs.dryRun ? 'would be deleted' : 'deleted'}`
  )
  if (failures.length) {
    throw new Error(`Cleanup failed for: ${failures.join(', ')}`)
  }
}

if (require.main === module) {
  main().catch(err => {
    console.log(`::error::${err.message}`)
    process.exit(1)
  })
}

module.exports = {
  parseInputs,
  packagePaths,
  selectVersions,
  cleanPackage
}
