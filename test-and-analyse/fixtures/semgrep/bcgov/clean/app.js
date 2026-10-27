// Safe counterparts of the findings fixture; expected to report nothing
const React = require('react');
const jwt = require('jsonwebtoken');
const DOMPurify = require('dompurify');
const key = process.env.DATA_ENCRYPTION_KEY;
if (!key) throw new Error('DATA_ENCRYPTION_KEY is required');
const port = process.env.PORT || '3000';
const host = process.env['HOST'] ?? 'localhost';
const opts = { algorithms: ['RS256'], audience: 'app', issuer: 'https://idp' };
jwt.verify(token, key, opts);
jwt.verify(token, key, { algorithms: ['RS256'], audience: 'app', issuer: 'https://idp' });
const el = <div dangerouslySetInnerHTML={{ __html: DOMPurify.sanitize(html) }} />;
const el2 = React.createElement('div', { dangerouslySetInnerHTML: { __html: DOMPurify.sanitize(html) } });
const props = { dangerouslySetInnerHTML: { __html: DOMPurify.sanitize(html) } };
const el3 = <div {...props} />;
module.exports = { key, port, host, el, el2, el3 };
