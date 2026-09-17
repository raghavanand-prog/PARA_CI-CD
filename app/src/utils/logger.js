'use strict';

const pino = require('pino');
const config = require('../config');

/**
 * Structured logger. Redacts any field that could contain a credential so
 * that passwords, tokens, and secrets are never written to logs/CloudWatch.
 */
const logger = pino({
  level: config.logLevel,
  redact: {
    paths: [
      'req.headers.authorization',
      'req.headers.cookie',
      'req.body.password',
      'req.body.confirmPassword',
      'req.body.token',
      '*.password',
      '*.token',
      '*.jwt',
      '*.secret',
      '*.authorization',
    ],
    censor: '[REDACTED]',
  },
  base: { service: 'secure-aws-cicd-demo-api' },
  timestamp: pino.stdTimeFunctions.isoTime,
});

module.exports = logger;
