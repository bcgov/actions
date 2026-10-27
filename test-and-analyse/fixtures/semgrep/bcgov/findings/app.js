// One hit per bcgov rule; counted by .github/workflows/test.yml
const jwt = require('jsonwebtoken');
const key = process.env.DATA_ENCRYPTION_KEY || 'defaultkey'; // env fallback
jwt.verify(token, key); // no algorithms + no aud/iss (2 findings)
const el = <div dangerouslySetInnerHTML={{ __html: html }} />; // XSS sink
module.exports = { key, el };
