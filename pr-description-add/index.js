'use strict';
// Thin entrypoint; the logic lives in ../shared/pr-description.js (also used by pr-validate).
const { getInput, InputError, assertKnownActionInputs } = require('../shared/inputs.js');
const { run } = require('../shared/pr-description.js');

// Undeclared inputs fail here; GitHub only warns (shared/README.md)
try {
  assertKnownActionInputs(__dirname);
} catch (e) {
  console.log(e instanceof InputError ? e.message : `::error::${e.message}`);
  process.exit(1);
}
if (!getInput('markdown')) {
  console.log('::error::markdown is required.');
  process.exit(1);
}
run().then((code) => process.exit(code));
