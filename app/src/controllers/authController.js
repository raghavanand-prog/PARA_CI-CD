'use strict';

const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const crypto = require('crypto');
const config = require('../config');
const userStore = require('../models/userStore');
const { ConflictError, AuthenticationError } = require('../utils/errors');

function issueToken(user) {
  return jwt.sign(
    { sub: user.id, email: user.email },
    config.jwt.secret,
    { expiresIn: config.jwt.expiresIn, issuer: config.jwt.issuer },
  );
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

    const token = issueToken(user);

    res.status(201).json({
      user: { id: user.id, email: user.email, name: user.name },
      token,
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

    const token = issueToken(user);

    res.status(200).json({
      user: { id: user.id, email: user.email, name: user.name },
      token,
    });
  } catch (err) {
    next(err);
  }
}

module.exports = { register, login };
