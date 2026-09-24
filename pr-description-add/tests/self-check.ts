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

// ncc must succeed; committed dist/ is refreshed at release, not on every PR.
const actionRoot = join(dirname(fileURLToPath(import.meta.url)), '..')
const repoRoot = join(actionRoot, '..')
if (!existsSync(join(repoRoot, 'node_modules'))) {
  execSync('npm ci', {cwd: repoRoot, stdio: 'inherit'})
}
execSync('npm run build && npm run package', {
  cwd: actionRoot,
  stdio: 'inherit'
})
console.log('Passed: ncc package build')
