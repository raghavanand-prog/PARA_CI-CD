'use strict';

/**
 * Basic integration tests exercising the full API surface end to end,
 * separate from the app package's own unit tests. Run with:
 *   cd app && npx jest --config ../tests/integration/jest.config.js
 * or via `make test` which wires the config for you.
 */
process.env.NODE_ENV = 'test';
process.env.JWT_SECRET = 'integration-test-secret-not-for-production';

const path = require('path');
const request = require(path.join(__dirname, '../../app/node_modules/supertest'));
const createApp = require(path.join(__dirname, '../../app/src/app'));
const userStore = require(path.join(__dirname, '../../app/src/models/userStore'));
const refreshTokenStore = require(path.join(__dirname, '../../app/src/models/refreshTokenStore'));

describe('API integration: register -> login -> profile', () => {
  const app = createApp();

  beforeEach(() => {
    userStore.clear();
    refreshTokenStore.clear();
  });

  it('supports the full user journey', async () => {
    const registerRes = await request(app)
      .post('/api/auth/register')
      .send({ email: 'integration@example.com', password: 'IntegrationPass1', name: 'Integration Tester' });
    expect(registerRes.status).toBe(201);

    const loginRes = await request(app)
      .post('/api/auth/login')
      .send({ email: 'integration@example.com', password: 'IntegrationPass1' });
    expect(loginRes.status).toBe(200);

    const profileRes = await request(app)
      .get('/api/users/profile')
      .set('Authorization', `Bearer ${loginRes.body.token}`);
    expect(profileRes.status).toBe(200);
    expect(profileRes.body.user.email).toBe('integration@example.com');
  });

  it('rejects unauthenticated profile access', async () => {
    const res = await request(app).get('/api/users/profile');
    expect(res.status).toBe(401);
  });

  it('supports refresh -> new access token -> logout -> revoked refresh token', async () => {
    const registerRes = await request(app)
      .post('/api/auth/register')
      .send({ email: 'refresh-flow@example.com', password: 'IntegrationPass1', name: 'Refresh Flow' });
    expect(registerRes.body.refreshToken).toBeDefined();

    const refreshRes = await request(app)
      .post('/api/auth/refresh')
      .send({ refreshToken: registerRes.body.refreshToken });
    expect(refreshRes.status).toBe(200);

    const profileRes = await request(app)
      .get('/api/users/profile')
      .set('Authorization', `Bearer ${refreshRes.body.token}`);
    expect(profileRes.status).toBe(200);

    const logoutRes = await request(app)
      .post('/api/auth/logout')
      .send({ refreshToken: refreshRes.body.refreshToken });
    expect(logoutRes.status).toBe(204);

    const refreshAfterLogout = await request(app)
      .post('/api/auth/refresh')
      .send({ refreshToken: refreshRes.body.refreshToken });
    expect(refreshAfterLogout.status).toBe(401);
  });

  it('reports health', async () => {
    const res = await request(app).get('/health');
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('ok');
  });
});
