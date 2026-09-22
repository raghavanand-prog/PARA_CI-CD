'use strict';

const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const crypto = require('crypto');
const config = require('../config');
const userStore = require('../models/userStore');
const refreshTokenStore = require('../models/refreshTokenStore');
const { ConflictError, AuthenticationError } = require('../utils/errors');

function issueAccessToken(user) {
  return jwt.sign(
    { sub: user.id, email: user.email },
    config.jwt.secret,
    { expiresIn: config.jwt.expiresIn, issuer: config.jwt.issuer },
  );
}

// Opaque, cryptographically random — not a JWT — specifically so it can be
// looked up and revoked server-side (see refreshTokenStore.js).
function issueRefreshToken(user) {
  const token = crypto.randomBytes(48).toString('hex');
  refreshTokenStore.create(token, {
    userId: user.id,
    email: user.email,
    expiresAt: Date.now() + config.refreshToken.expiresInMs,
  });
  return token;
}

function issueTokenPair(user) {
  return { token: issueAccessToken(user), refreshToken: issueRefreshToken(user) };
}

async function register(req, res, next) {
  try {
    const { email, password, name } = req.body;

    if (userStore.findByEmail(email)) {
      throw new ConflictError('An account with this email already exists');
    }

    const passwordHash = await bcrypt.hash(password, config.bcrypt.saltRounds);

    const user = userStore.create({
      id: crypto.randomUUID(),
      email,
      name,
      passwordHash,
      createdAt: new Date().toISOString(),
    });

    res.status(201).json({
      user: { id: user.id, email: user.email, name: user.name },
      ...issueTokenPair(user),
    });
  } catch (err) {
    next(err);
  }
}

async function login(req, res, next) {
  try {
    const { email, password } = req.body;
    const user = userStore.findByEmail(email);

    // Constant-shape response to avoid user-enumeration timing differences:
    // always run bcrypt.compare against SOME hash, even for a nonexistent
    // user, so response timing doesn't leak whether the email is registered.
    // This is a fixed, publicly-known bcrypt hash of an arbitrary string —
    // not a credential for any real account — so scanners that flag
    // hardcoded-secret-shaped literals are a false positive here; removing
    // it would reintroduce the timing side-channel it exists to prevent.
    // nosemgrep
    const dummyHash = '$2a$12$CwTycUXWue0Thq9StjUM0uJ8yqYXt5rQmUxRlqrRtG3jsBb.i0K.C';
    const hashToCompare = user ? user.passwordHash : dummyHash;
    const passwordMatches = await bcrypt.compare(password, hashToCompare);

    if (!user || !passwordMatches) {
      throw new AuthenticationError('Invalid email or password');
    }

    res.status(200).json({
      user: { id: user.id, email: user.email, name: user.name },
      ...issueTokenPair(user),
    });
  } catch (err) {
    next(err);
  }
}

// Exchanges a still-valid refresh token for a new access token. The
// refresh token itself is rotated (old one revoked, new one issued) on
// every use: if a stolen refresh token is ever used by an attacker, the
// legitimate client's next refresh attempt will fail with the old token
// already gone, which is a detectable signal — a refresh token that's
// reused indefinitely without rotation loses that property.
async function refresh(req, res, next) {
  try {
    const { refreshToken } = req.body;
    const record = refreshTokenStore.get(refreshToken);

    if (!record) {
      throw new AuthenticationError('Invalid or expired refresh token');
    }

    refreshTokenStore.revoke(refreshToken);
    const user = { id: record.userId, email: record.email };

    res.status(200).json(issueTokenPair(user));
  } catch (err) {
    next(err);
  }
}

// Revokes a refresh token so it can no longer be exchanged for a new
// access token. Deliberately idempotent (revoking an already-unknown
// token still returns 204) rather than leaking whether a given refresh
// token was ever valid.
async function logout(req, res, next) {
  try {
    const { refreshToken } = req.body;
    refreshTokenStore.revoke(refreshToken);
    res.status(204).send();
  } catch (err) {
    next(err);
  }
}

module.exports = { register, login, refresh, logout };
