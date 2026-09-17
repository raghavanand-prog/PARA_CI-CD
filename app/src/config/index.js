'use strict';

/**
 * Centralized, env-driven configuration.
 * No secrets are hardcoded here — everything is read from process.env,
 * which in AWS is populated from Secrets Manager / SSM Parameter Store
 * via the ECS task definition, and locally from a .env file (see .env.example).
 */
require('dotenv').config();

function required(name, fallback) {
  const value = process.env[name] ?? fallback;
  if (value === undefined || value === null || value === '') {
    if (process.env.NODE_ENV === 'test') {
      // Tests provide their own safe defaults so the suite never needs real secrets.
      return fallback;
    }
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

const config = {
  env: process.env.NODE_ENV || 'development',
  port: parseInt(process.env.PORT || '3000', 10),
  awsRegion: process.env.AWS_REGION || 'us-east-1',
  jwt: {
    secret: required('JWT_SECRET', 'test-only-insecure-secret-do-not-use-in-prod'),
    expiresIn: process.env.JWT_EXPIRES_IN || '1h',
    issuer: process.env.JWT_ISSUER || 'secure-aws-cicd-demo-api',
  },
  bcrypt: {
    saltRounds: parseInt(process.env.BCRYPT_SALT_ROUNDS || '12', 10),
  },
  rateLimit: {
    windowMs: parseInt(process.env.RATE_LIMIT_WINDOW_MS || '900000', 10), // 15 min
    max: parseInt(process.env.RATE_LIMIT_MAX || '100', 10),
  },
  logLevel: process.env.LOG_LEVEL || 'info',
};

module.exports = config;
