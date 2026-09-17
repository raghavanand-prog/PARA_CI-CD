'use strict';

const logger = require('../utils/logger');

/**
 * Centralized error handler. Returns consistent JSON error bodies and never
 * leaks stack traces or internal details in production responses.
 */
// eslint-disable-next-line no-unused-vars
function errorHandler(err, req, res, next) {
  const statusCode = err.statusCode || 500;
  const isOperational = err.isOperational === true;

  logger.error({
    err: { name: err.name, message: err.message, stack: err.stack },
    path: req.path,
    method: req.method,
  }, 'request error');

  const body = {
    error: {
      message: isOperational ? err.message : 'Internal server error',
      code: err.name || 'InternalError',
    },
  };

  if (err.details) {
    body.error.details = err.details;
  }

  res.status(statusCode).json(body);
}

function notFoundHandler(req, res) {
  res.status(404).json({ error: { message: 'Not found', code: 'NotFound' } });
}

module.exports = { errorHandler, notFoundHandler };
