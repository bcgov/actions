// Safe counterparts of the findings fixture; expected to report nothing
const jwt = require('jsonwebtoken');
const DOMPurify = require('dompurify');
const key = process.env.DATA_ENCRYPTION_KEY;
if (!key) throw new Error('DATA_ENCRYPTION_KEY is required');
const port = process.env.PORT || '3000';
jwt.verify(token, key, { algorithms: ['RS256'], audience: 'app', issuer: 'https://idp' });
const el = <div dangerouslySetInnerHTML={{ __html: DOMPurify.sanitize(html) }} />;
module.exports = { key, port, el };
