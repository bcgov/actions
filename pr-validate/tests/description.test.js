const test = require('node:test');
const assert = require('node:assert');
const { alreadyPresent, appendBody, normalizeText } = require('../description.js');

test('normalizeText trims line ends and CRLF', () => {
  assert.strictEqual(normalizeText(' a  \r\nb\r\n'), 'a\nb');
});
test('checkbox state does not count as different', () => {
  assert.ok(alreadyPresent('intro\n\n- [x] done', '- [ ] done'));
  assert.ok(!alreadyPresent('intro', '- [ ] done'));
});
test('appendBody separates with a blank line', () => {
  assert.strictEqual(appendBody('body\n', 'md'), 'body\n\nmd');
  assert.strictEqual(appendBody('', 'md'), 'md');
});
