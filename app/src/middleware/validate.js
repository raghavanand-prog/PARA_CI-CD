'use strict';

const { validationResult } = require('express-validator');
const { ValidationError } = require('../utils/errors');

/**
 * Runs express-validator chains then converts failures into a single
 * ValidationError handled centrally by the error handler.
 */
function validate(validations) {
  return async (req, res, next) => {
    await Promise.all(validations.map((validation) => validation.run(req)));

    const errors = validationResult(req);
    if (errors.isEmpty()) {
      return next();
    }

    const details = errors.array().map((e) => ({ field: e.path, message: e.msg }));
    return next(new ValidationError(details));
  };
}

module.exports = { validate };
