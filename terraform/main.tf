terraform {
  required_version = ">= 1.7"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.0" }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags { tags = { Project = var.project, Environment = var.env, ManagedBy = "Terraform" } }
}

locals {
  prefix   = "${var.project}-${var.env}"
  is_prod  = var.env == "prod"
}

# ── KMS CMK ──────────────────────────────────────────────
resource "aws_kms_key" "main" {
  description             = "${local.prefix} CMK"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "Root", Effect = "Allow", Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }, Action = "kms:*", Resource = "*" },
      { Sid = "Lambda", Effect = "Allow", Principal = { AWS = aws_iam_role.lambda.arn }, Action = ["kms:Decrypt", "kms:GenerateDataKey"], Resource = "*" },
      { Sid = "CWLogs", Effect = "Allow", Principal = { Service = "logs.${var.aws_region}.amazonaws.com" }, Action = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"], Resource = "*" }
    ]
  })
}
resource "aws_kms_alias" "main" { name = "alias/${local.prefix}"; target_key_id = aws_kms_key.main.key_id }

data "aws_caller_identity" "current" {}

# ── DynamoDB ─────────────────────────────────────────────
resource "aws_dynamodb_table" "items" {
  name         = "${local.prefix}-items"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"
  attribute { name = "PK"; type = "S" }
  attribute { name = "SK"; type = "S" }
  point_in_time_recovery { enabled = true }
  server_side_encryption { enabled = true; kms_master_key_id = aws_kms_key.main.arn }
  deletion_protection_enabled = local.is_prod
}

# ── SQS DLQ ──────────────────────────────────────────────
resource "aws_sqs_queue" "dlq" {
  name                      = "${local.prefix}-dlq"
  kms_master_key_id         = aws_kms_key.main.id
  message_retention_seconds = 1209600
}

# ── IAM Role for Lambda ───────────────────────────────────
resource "aws_iam_role" "lambda" {
  name = "${local.prefix}-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}
resource "aws_iam_role_policy" "lambda" {
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["dynamodb:GetItem","dynamodb:PutItem","dynamodb:UpdateItem","dynamodb:DeleteItem","dynamodb:Query"], Resource = aws_dynamodb_table.items.arn },
      { Effect = "Allow", Action = ["sqs:SendMessage"], Resource = aws_sqs_queue.dlq.arn },
      { Effect = "Allow", Action = ["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"], Resource = "arn:aws:logs:*:*:*" },
      { Effect = "Allow", Action = ["xray:PutTraceSegments","xray:PutTelemetryRecords"], Resource = "*" },
      { Effect = "Allow", Action = ["kms:Decrypt","kms:GenerateDataKey"], Resource = aws_kms_key.main.arn }
    ]
  })
}

# ── CloudWatch Log Group for Lambda ──────────────────────
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.prefix}-handler"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.main.arn
}

# ── Lambda Function ───────────────────────────────────────
data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/../src/index.mjs"
  output_path = "${path.module}/.build/lambda.zip"
}
resource "aws_lambda_function" "handler" {
  function_name    = "${local.prefix}-handler"
  role             = aws_iam_role.lambda.arn
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  runtime          = "nodejs20.x"
  handler          = "index.handler"
  architectures    = ["arm64"]
  memory_size      = 256
  timeout          = 10
  tracing_config { mode = "Active" }
  dead_letter_config { target_arn = aws_sqs_queue.dlq.arn }
  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.items.name
      LOG_LEVEL  = "INFO"
    }
  }
  depends_on = [aws_cloudwatch_log_group.lambda]
}

# ── API Gateway ───────────────────────────────────────────
resource "aws_cloudwatch_log_group" "apigw" {
  name              = "/aws/apigateway/${local.prefix}"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.main.arn
}
resource "aws_api_gateway_rest_api" "api" {
  name = "${local.prefix}-api"
  endpoint_configuration { types = ["REGIONAL"] }
}
resource "aws_api_gateway_resource" "items" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "items"
}
resource "aws_api_gateway_method" "any" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.items.id
  http_method   = "ANY"
  authorization = "NONE"
}
resource "aws_api_gateway_integration" "lambda" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.items.id
  http_method             = aws_api_gateway_method.any.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.handler.invoke_arn
}
resource "aws_lambda_permission" "apigw" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.handler.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.api.execution_arn}/*/*"
}
resource "aws_api_gateway_deployment" "v1" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  depends_on  = [aws_api_gateway_integration.lambda]
  lifecycle   { create_before_destroy = true }
}
resource "aws_iam_role" "apigw_cw" {
  name = "${local.prefix}-apigw-cw-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "apigateway.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
  managed_policy_arns = ["arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"]
}
resource "aws_api_gateway_account" "main" { cloudwatch_role_arn = aws_iam_role.apigw_cw.arn }
resource "aws_api_gateway_stage" "v1" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  deployment_id = aws_api_gateway_deployment.v1.id
  stage_name    = "v1"
  xray_tracing_enabled = true
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.apigw.arn
    format = jsonencode({ requestId = "$context.requestId", ip = "$context.identity.sourceIp", method = "$context.httpMethod", path = "$context.path", status = "$context.status", latency = "$context.responseLatency" })
  }
  default_route_settings { throttling_rate_limit = 1000; throttling_burst_limit = 2000 }
  depends_on = [aws_api_gateway_account.main]
}

# ── CloudWatch Alarms ─────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${local.prefix}-lambda-errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.handler.function_name }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  alarm_description   = "Lambda error count >= 5 in 1 min"
  treat_missing_data  = "notBreaching"
}
resource "aws_cloudwatch_metric_alarm" "apigw_5xx" {
  alarm_name          = "${local.prefix}-apigw-5xx"
  namespace           = "AWS/ApiGateway"
  metric_name         = "5XXError"
  dimensions          = { ApiName = aws_api_gateway_rest_api.api.name, Stage = "v1" }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 10
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
}