'use strict';
// input-enforcer action: compare the calling action's `toJSON(inputs)` with
// the inputs its action.yml declares; fail on any it does not.
const { enforce, jsonKeys, run } = require('./enforce.js');

const input = name => String(process.env[`INPUT_${name.toUpperCase()}`] ?? '').trim();

run(() => {
  const dir = input('action_path');
  if (!dir) throw new Error('action_path is required: pass ${{ github.action_path }}');
  enforce(dir, jsonKeys(input('inputs')), { raw: true });
});
