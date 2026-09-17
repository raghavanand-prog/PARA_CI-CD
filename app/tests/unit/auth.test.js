'use strict';

process.env.NODE_ENV = 'test';
process.env.JWT_SECRET = 'unit-test-secret-not-for-production';

const request = require('supertest');
const jwt = require('jsonwebtoken');
const createApp = require('../../src/app');
const userStore = require('../../src/models/userStore');
const config = require('../../src/config');

describe('auth flow', () => {
  const app = createApp();

  beforeEach(() => {
    userStore.clear();
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
