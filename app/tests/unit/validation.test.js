'use strict';

process.env.NODE_ENV = 'test';
process.env.JWT_SECRET = 'unit-test-secret-not-for-production';

const request = require('supertest');
const createApp = require('../../src/app');

describe('input validation', () => {
  const app = createApp();

  it('rejects registration with an invalid email', async () => {
    const res = await request(app)
      .post('/api/auth/register')
      .send({ email: 'not-an-email', password: 'ValidPass123', name: 'Test' });

    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('ValidationError');
  });

  it('rejects registration with a weak password', async () => {
    const res = await request(app)
      .post('/api/auth/register')
      .send({ email: 'weak@example.com', password: 'short', name: 'Test' });

    expect(res.status).toBe(400);
    expect(
      res.body.error.details.some((d) => d.field === 'password'),
    ).toBe(true);
  });

  it('rejects registration with a missing name', async () => {
    const res = await request(app)
      .post('/api/auth/register')
      .send({ email: 'noname@example.com', password: 'ValidPass123' });

    expect(res.status).toBe(400);
  });

  it('rejects login with missing password', async () => {
    const res = await request(app)
      .post('/api/auth/login')
      .send({ email: 'someone@example.com' });

    expect(res.status).toBe(400);
  });
});
