// Findings counted by .github/workflows/test.yml
const jwt = require('jsonwebtoken');
const key = process.env.DATA_ENCRYPTION_KEY || 'defaultkey'; // env fallback
const k2 = process.env['JWT_SECRET'] || 'dev'; // env fallback, bracket ||
const k3 = process.env['API_TOKEN'] ?? 'dev'; // env fallback, bracket ??
jwt.verify(token, key); // no algorithms + no aud/iss (2 findings)
jwt.verify(token, key, function (err, decoded) {}); // callback only (2 findings)
const el = <div dangerouslySetInnerHTML={{ __html: html }} />; // XSS sink
const props = { dangerouslySetInnerHTML: { __html: html } }; // XSS sink, props object
module.exports = { key, k2, k3, el, props };
