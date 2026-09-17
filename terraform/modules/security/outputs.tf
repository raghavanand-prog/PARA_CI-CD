output "kms_key_id" {
  value = aws_kms_key.main.key_id
}

output "kms_key_arn" {
  value = aws_kms_key.main.arn
}

output "jwt_secret_arn" {
  value = aws_secretsmanager_secret.jwt_secret.arn
}

output "log_level_ssm_arn" {
  value = aws_ssm_parameter.log_level.arn
}

output "rate_limit_ssm_arn" {
  value = aws_ssm_parameter.rate_limit_max.arn
}
