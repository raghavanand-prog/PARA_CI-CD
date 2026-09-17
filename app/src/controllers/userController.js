'use strict';

const userStore = require('../models/userStore');
const { AuthenticationError } = require('../utils/errors');

async function getProfile(req, res, next) {
  try {
    const user = userStore.findByEmail(req.user.email);
    if (!user) {
      throw new AuthenticationError('User no longer exists');
    }

    res.status(200).json({
      user: { id: user.id, email: user.email, name: user.name, createdAt: user.createdAt },
    });
  } catch (err) {
    next(err);
  }
}

module.exports = { getProfile };
