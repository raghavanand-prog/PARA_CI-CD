'use strict';

const express = require('express');
const { body } = require('express-validator');
const { validate } = require('../middleware/validate');
const authController = require('../controllers/authController');

const router = express.Router();

const registerValidation = [
  body('email').isEmail().normalizeEmail().withMessage('A valid email is required'),
  body('password')
    .isString()
    .isLength({ min: 10 })
    .withMessage('Password must be at least 10 characters')
    .matches(/[A-Z]/)
    .withMessage('Password must contain an uppercase letter')
    .matches(/[a-z]/)
    .withMessage('Password must contain a lowercase letter')
    .matches(/\d/)
    .withMessage('Password must contain a digit'),
  body('name').isString().trim().isLength({ min: 1, max: 100 }).withMessage('Name is required'),
];

const loginValidation = [
  body('email').isEmail().normalizeEmail().withMessage('A valid email is required'),
  body('password').isString().notEmpty().withMessage('Password is required'),
];

const refreshTokenValidation = [
  body('refreshToken').isString().notEmpty().withMessage('refreshToken is required'),
];

router.post('/register', validate(registerValidation), authController.register);
router.post('/login', validate(loginValidation), authController.login);
router.post('/refresh', validate(refreshTokenValidation), authController.refresh);
router.post('/logout', validate(refreshTokenValidation), authController.logout);

module.exports = router;
