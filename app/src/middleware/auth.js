'use strict';

const jwt = require('jsonwebtoken');
const config = require('../config');
const { AuthenticationError } = require('../utils/errors');

/**
 * Verifies a Bearer JWT and attaches the decoded payload to req.user.
 * Never logs the raw token (see logger redaction config).
 */
function authenticate(req, res, next) {
  const header = req.headers.authorization || '';
  const [scheme, token] = header.split(' ');

  if (scheme !== 'Bearer' || !token) {
    return next(new AuthenticationError('Missing or malformed Authorization header'));
  }

  try {
    const payload = jwt.verify(token, config.jwt.secret, {
      issuer: config.jwt.issuer,
    });
    req.user = payload;
    return next();
  } catch (err) {
    return next(new AuthenticationError('Invalid or expired token'));
  }
}

module.exports = { authenticate };
