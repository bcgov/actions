import assert from 'node:assert/strict'
import {execSync} from 'node:child_process'
import {existsSync} from 'node:fs'
import {dirname, join} from 'node:path'
import {fileURLToPath} from 'node:url'
import {normalizeCheckboxState, normalizeText} from '../src/compare.ts'

const checked = normalizeCheckboxState('- [x] Deploy frontend')
const unchecked = normalizeCheckboxState('- [ ] Deploy frontend')
assert.equal(checked, unchecked)
assert.equal(checked, '- [ ] Deploy frontend')

const mixed = normalizeCheckboxState('- [X] One\n- [ ] Two')
assert.equal(mixed, '- [ ] One\n- [ ] Two')

const body = normalizeText('Hello\n\n- [x] Deploy frontend\n')
const block = normalizeCheckboxState(normalizeText('- [ ] Deploy frontend'))
assert.equal(normalizeCheckboxState(body).includes(block), true)

const emptyCompare = normalizeCheckboxState(
  normalizeText('- [x] Deploy frontend')
)
assert.notEqual(emptyCompare, '')

console.log('Passed: 5, Failed: 0')

// Dist freshness (#99 slice): committed dist/ must match a fresh package build.
const actionRoot = join(dirname(fileURLToPath(import.meta.url)), '..')
const repoRoot = join(actionRoot, '..')
if (!existsSync(join(repoRoot, 'node_modules'))) {
  execSync('npm ci', {cwd: repoRoot, stdio: 'inherit'})
}
execSync(
  'npm run build && npm run package && git diff --ignore-space-at-eol --exit-code dist/ && test -z "$(git ls-files --others --exclude-standard -- dist/)"',
  {cwd: actionRoot, stdio: 'inherit'}
)
console.log('Passed: dist/ matches fresh build')
