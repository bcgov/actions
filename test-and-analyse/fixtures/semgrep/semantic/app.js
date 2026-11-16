const jwt = require('jsonwebtoken');
const axios = require('axios');
const express = require('express');
const router = express.Router();

const secret = process.env.JWT_SECRET || 'dev-secret';

function badVerify(token, pubKey, accessToken) {
  return jwt.verify(token, pubKey);
}

async function badLogging(accessToken) {
  try {
    await axios.get('/api/data');
  } catch (err) {
    console.error(err);
  }
  console.info(`Authorization token: ${accessToken}`);
  console.info(`Token refresh failed: ${responseStatus}`);
}

router.post('/items', (req, res) => res.sendStatus(200));
router.post('/auth/login', (req, res) => res.sendStatus(200));
