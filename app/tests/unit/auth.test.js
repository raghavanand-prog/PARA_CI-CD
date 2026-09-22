'use strict';

process.env.NODE_ENV = 'test';
process.env.JWT_SECRET = 'unit-test-secret-not-for-production';

const request = require('supertest');
const jwt = require('jsonwebtoken');
const createApp = require('../../src/app');
const userStore = require('../../src/models/userStore');
const refreshTokenStore = require('../../src/models/refreshTokenStore');
const config = require('../../src/config');

describe('auth flow', () => {
  const app = createApp();

  beforeEach(() => {
    userStore.clear();
    refreshTokenStore.clear();
  });

  it('registers a new user and returns a JWT', async () => {
    const res = await request(app)
      .post('/api/auth/register')
      .send({ email: 'alice@example.com', password: 'StrongPass123', name: 'Alice' });

    expect(res.status).toBe(201);
    expect(res.body.token).toBeDefined();
    expect(res.body.user.email).toBe('alice@example.com');

    const decoded = jwt.verify(res.body.token, config.jwt.secret, { issuer: config.jwt.issuer });
    expect(decoded.email).toBe('alice@example.com');
  });

  it('rejects duplicate registration with 409', async () => {
    await request(app)
      .post('/api/auth/register')
      .send({ email: 'bob@example.com', password: 'StrongPass123', name: 'Bob' });

    const res = await request(app)
      .post('/api/auth/register')
      .send({ email: 'bob@example.com', password: 'StrongPass123', name: 'Bob' });

    expect(res.status).toBe(409);
  });

  it('logs in with correct credentials', async () => {
    await request(app)
      .post('/api/auth/register')
      .send({ email: 'carol@example.com', password: 'StrongPass123', name: 'Carol' });

    const res = await request(app)
      .post('/api/auth/login')
      .send({ email: 'carol@example.com', password: 'StrongPass123' });

    expect(res.status).toBe(200);
    expect(res.body.token).toBeDefined();
  });

  it('rejects login with wrong password', async () => {
    await request(app)
      .post('/api/auth/register')
      .send({ email: 'dave@example.com', password: 'StrongPass123', name: 'Dave' });

    const res = await request(app)
      .post('/api/auth/login')
      .send({ email: 'dave@example.com', password: 'WrongPass123' });

    expect(res.status).toBe(401);
  });

  it('rejects login for unknown user without leaking existence', async () => {
    const res = await request(app)
      .post('/api/auth/login')
      .send({ email: 'ghost@example.com', password: 'WhateverPass123' });

    expect(res.status).toBe(401);
    expect(res.body.error.message).toBe('Invalid email or password');
  });

  it('never returns the password hash in responses', async () => {
    const res = await request(app)
      .post('/api/auth/register')
      .send({ email: 'erin@example.com', password: 'StrongPass123', name: 'Erin' });

    expect(res.body.user.passwordHash).toBeUndefined();
    expect(JSON.stringify(res.body)).not.toMatch(/passwordHash|\$2[aby]\$/);
  });

  it('also issues a refresh token on register and login', async () => {
    const registerRes = await request(app)
      .post('/api/auth/register')
      .send({ email: 'gina@example.com', password: 'StrongPass123', name: 'Gina' });
    expect(registerRes.body.refreshToken).toBeDefined();

    const loginRes = await request(app)
      .post('/api/auth/login')
      .send({ email: 'gina@example.com', password: 'StrongPass123' });
    expect(loginRes.body.refreshToken).toBeDefined();
    expect(loginRes.body.refreshToken).not.toBe(registerRes.body.refreshToken);
  });
});

describe('refresh token flow', () => {
  const app = createApp();

  beforeEach(() => {
    userStore.clear();
    refreshTokenStore.clear();
  });

  it('exchanges a valid refresh token for a new token pair', async () => {
    const registerRes = await request(app)
      .post('/api/auth/register')
      .send({ email: 'hank@example.com', password: 'StrongPass123', name: 'Hank' });

    const refreshRes = await request(app)
      .post('/api/auth/refresh')
      .send({ refreshToken: registerRes.body.refreshToken });

    expect(refreshRes.status).toBe(200);
    expect(refreshRes.body.token).toBeDefined();
    expect(refreshRes.body.refreshToken).toBeDefined();
    // Not asserting the new access token differs from the old one: a JWT's
    // `iat` claim has second-level granularity, so two tokens issued for
    // the same user within the same second are legitimately byte-identical
    // — that's correct JWT behavior, not something to test against. The
    // refresh *token* rotating (covered below) is the actual security
    // property under test here.

    const decoded = jwt.verify(refreshRes.body.token, config.jwt.secret, { issuer: config.jwt.issuer });
    expect(decoded.email).toBe('hank@example.com');
  });

  it('rotates the refresh token, invalidating the previous one', async () => {
    const registerRes = await request(app)
      .post('/api/auth/register')
      .send({ email: 'iris@example.com', password: 'StrongPass123', name: 'Iris' });

    const firstRefresh = await request(app)
      .post('/api/auth/refresh')
      .send({ refreshToken: registerRes.body.refreshToken });
    expect(firstRefresh.status).toBe(200);
    expect(firstRefresh.body.refreshToken).not.toBe(registerRes.body.refreshToken);

    const reuseOldToken = await request(app)
      .post('/api/auth/refresh')
      .send({ refreshToken: registerRes.body.refreshToken });
    expect(reuseOldToken.status).toBe(401);
  });

  it('rejects an unknown refresh token', async () => {
    const res = await request(app)
      .post('/api/auth/refresh')
      .send({ refreshToken: 'this-was-never-issued' });
    expect(res.status).toBe(401);
  });

  it('rejects a missing refreshToken field with a validation error', async () => {
    const res = await request(app).post('/api/auth/refresh').send({});
    expect(res.status).toBe(400);
  });

  it('revokes a refresh token on logout so it can no longer be used', async () => {
    const registerRes = await request(app)
      .post('/api/auth/register')
      .send({ email: 'jack@example.com', password: 'StrongPass123', name: 'Jack' });

    const logoutRes = await request(app)
      .post('/api/auth/logout')
      .send({ refreshToken: registerRes.body.refreshToken });
    expect(logoutRes.status).toBe(204);

    const refreshAfterLogout = await request(app)
      .post('/api/auth/refresh')
      .send({ refreshToken: registerRes.body.refreshToken });
    expect(refreshAfterLogout.status).toBe(401);
  });

  it('logout is idempotent for an already-unknown refresh token', async () => {
    const res = await request(app)
      .post('/api/auth/logout')
      .send({ refreshToken: 'never-issued-or-already-revoked' });
    expect(res.status).toBe(204);
  });
});

describe('protected profile route', () => {
  const app = createApp();

  beforeEach(() => {
    userStore.clear();
  });

  it('rejects requests without a token', async () => {
    const res = await request(app).get('/api/users/profile');
    expect(res.status).toBe(401);
  });

  it('rejects requests with an invalid token', async () => {
    const res = await request(app)
      .get('/api/users/profile')
      .set('Authorization', 'Bearer not-a-real-token');
    expect(res.status).toBe(401);
  });

  it('returns the profile for a valid token', async () => {
    const register = await request(app)
      .post('/api/auth/register')
      .send({ email: 'frank@example.com', password: 'StrongPass123', name: 'Frank' });

    const res = await request(app)
      .get('/api/users/profile')
      .set('Authorization', `Bearer ${register.body.token}`);

    expect(res.status).toBe(200);
    expect(res.body.user.email).toBe('frank@example.com');
  });
});
