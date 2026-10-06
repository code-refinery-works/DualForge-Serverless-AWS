output "api_endpoint" {
  description = "REST API invoke URL (v1 stage)"
  value       = "${aws_api_gateway_stage.v1.invoke_url}/items"
}

output "lambda_function_name" {
  description = "Lambda function name"
  value       = aws_lambda_function.handler.function_name
}

output "dynamodb_table_name" {
  description = "DynamoDB table name"
  value       = aws_dynamodb_table.items.name
}

output "kms_key_arn" {
  description = "KMS CMK ARN used for encryption"
  value       = aws_kms_key.main.arn
  sensitive   = true
}

output "dlq_url" {
  description = "SQS Dead Letter Queue URL"
  value       = aws_sqs_queue.dlq.url
}