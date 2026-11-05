'use strict';
// Thin entrypoint; the logic lives in ../shared/pr-description.js (also used by pr-validate).
const { getInput, InputError } = require('../shared/inputs.js');
const { run } = require('../shared/pr-description.js');

// Undeclared inputs fail here; GitHub only warns (input-enforcer/README.md)
require('../input-enforcer/enforce.js').enforceNode(__dirname);
if (!getInput('markdown')) {
  console.log('::error::markdown is required.');
  process.exit(1);
}
run().then((code) => process.exit(code));
