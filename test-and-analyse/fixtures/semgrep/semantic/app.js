const jwt = require('jsonwebtoken');
const axios = require('axios');
const express = require('express');
const router = express.Router();
const protectedRouter = express.Router();

router.use(express.json());
protectedRouter.use(requireAuth);

const secret = process.env.JWT_SECRET || 'dev-secret';

function badVerify(token, pubKey) {
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
router.post('/authors', (req, res) => res.sendStatus(200));
router.post('/auth/login', (req, res) => res.sendStatus(200));
protectedRouter.post('/admin/items', (req, res) => res.sendStatus(200));
