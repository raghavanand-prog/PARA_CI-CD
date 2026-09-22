'use strict';

const path = require('path');
const express = require('express');
const helmet = require('helmet');
const rateLimit = require('express-rate-limit');
const pinoHttp = require('pino-http');

const config = require('./config');
const logger = require('./utils/logger');
const healthRouter = require('./routes/health');
const authRouter = require('./routes/auth');
const usersRouter = require('./routes/users');
const { errorHandler, notFoundHandler } = require('./middleware/errorHandler');

function createApp() {
  const app = express();

  // Secure HTTP headers (CSP, HSTS, X-Frame-Options, etc.)
  app.use(helmet());

  app.use(express.json({ limit: '10kb' }));

  app.use(
    pinoHttp({
      logger,
      redact: ['req.headers.authorization', 'req.headers.cookie'],
      customLogLevel: (req, res, err) => {
        if (res.statusCode >= 500 || err) return 'error';
        if (res.statusCode >= 400) return 'warn';
        return 'info';
      },
    }),
  );

  // Global rate limiting to slow down brute-force / credential-stuffing attacks.
  app.use(
    rateLimit({
      windowMs: config.rateLimit.windowMs,
      max: config.rateLimit.max,
      standardHeaders: true,
      legacyHeaders: false,
      message: { error: { message: 'Too many requests', code: 'RateLimited' } },
    }),
  );

  app.use('/health', healthRouter);
  app.use('/api/auth', authRouter);
  app.use('/api/users', usersRouter);

  // Serves the same demo UI (login page, dashboard) that runs on Vercel.
  // `extensions: ['html']` makes clean URLs work the same way Vercel's
  // `cleanUrls: true` does — a request for /login is resolved against
  // public/login.html without a redirect. Mounted after the API routes so
  // it never shadows them, and before notFoundHandler so unmatched static
  // paths still fall through to a proper 404.
  app.use(express.static(path.join(__dirname, '../public'), { extensions: ['html'] }));

  app.use(notFoundHandler);
  app.use(errorHandler);

  return app;
}

module.exports = createApp;
