import assert from 'node:assert/strict'
import {
  normalizeCheckboxState,
  normalizeText
} from '../src/compare.ts'

const checked = normalizeCheckboxState('- [x] Deploy frontend')
const unchecked = normalizeCheckboxState('- [ ] Deploy frontend')
assert.equal(checked, unchecked)
assert.equal(checked, '- [ ] Deploy frontend')

const mixed = normalizeCheckboxState('- [X] One\n- [ ] Two')
assert.equal(mixed, '- [ ] One\n- [ ] Two')

const body = normalizeText('Hello\n\n- [x] Deploy frontend\n')
const block = normalizeCheckboxState(
  normalizeText('- [ ] Deploy frontend')
)
assert.equal(normalizeCheckboxState(body).includes(block), true)

const emptyCompare = normalizeCheckboxState(normalizeText('- [x] Deploy frontend'))
assert.notEqual(emptyCompare, '')

console.log('Passed: 5, Failed: 0')
