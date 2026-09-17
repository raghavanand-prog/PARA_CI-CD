'use strict';

/**
 * In-memory user store for demo purposes.
 * In a real deployment this would be replaced by a managed database
 * (e.g. RDS/DynamoDB) accessed via credentials pulled from Secrets Manager.
 * Kept intentionally simple so the pipeline/security-gate demo stays focused.
 */
class UserStore {
  constructor() {
    this.usersByEmail = new Map();
  }

  findByEmail(email) {
    return this.usersByEmail.get(email.toLowerCase());
  }

  create(user) {
    const record = { ...user, email: user.email.toLowerCase() };
    this.usersByEmail.set(record.email, record);
    return record;
  }

  clear() {
    this.usersByEmail.clear();
  }
}

module.exports = new UserStore();
module.exports.UserStore = UserStore;
