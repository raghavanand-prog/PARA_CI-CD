'use strict';

/**
 * In-memory refresh-token store for demo purposes (see userStore.js for the
 * same caveat — a real deployment would use RDS/DynamoDB, not a Map).
 *
 * Unlike the access token (a stateless, self-verifying JWT), refresh tokens
 * are deliberately opaque, random strings tracked server-side. That's the
 * whole point of this store: a JWT can't be revoked early without either
 * maintaining a blocklist (which defeats the "stateless" benefit) or
 * keeping expiry very short. Tracking refresh tokens here means logout, or
 * a detected compromise, can actually invalidate a session — something a
 * bare JWT-only design cannot do.
 */
class RefreshTokenStore {
  constructor() {
    this.tokensById = new Map();
  }

  create(token, { userId, email, expiresAt }) {
    this.tokensById.set(token, { userId, email, expiresAt });
    return token;
  }

  /** Returns the record if the token exists and hasn't expired, else null. */
  get(token) {
    const record = this.tokensById.get(token);
    if (!record) return null;
    if (Date.now() >= record.expiresAt) {
      this.tokensById.delete(token);
      return null;
    }
    return record;
  }

  revoke(token) {
    return this.tokensById.delete(token);
  }

  clear() {
    this.tokensById.clear();
  }
}

module.exports = new RefreshTokenStore();
module.exports.RefreshTokenStore = RefreshTokenStore;
