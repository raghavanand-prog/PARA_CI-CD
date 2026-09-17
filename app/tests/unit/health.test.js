'use strict';

process.env.NODE_ENV = 'test';
process.env.JWT_SECRET = 'unit-test-secret-not-for-production';

const request = require('supertest');
const createApp = require('../../src/app');

describe('GET /health', () => {
  const app = createApp();

  it('returns 200 and an ok status', async () => {
    const res = await request(app).get('/health');
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('ok');
    expect(typeof res.body.uptimeSeconds).toBe('number');
  });
});
