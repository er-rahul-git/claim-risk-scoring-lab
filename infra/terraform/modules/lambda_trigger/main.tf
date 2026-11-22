# Trigger Lambda: S3 event on requests/*.json -> POST the S3 path to the internal API.
# Failures retry twice, then land in a dead-letter queue that raises an alarm.
variable "name_prefix" { type = string }
variable "source_dir" { type = string }
variable "role_arn" { type = string }
variable "subnet_ids" { type = list(string) }
variable "security_group_ids" { type = list(string) }
variable "api_url" { type = string }
variable "bucket_arn" { type = string }
variable "dlq_name" { type = string }
variable "alarm_topic_arn" { type = string }

locals {
  function_name = "${var.name_prefix}-trigger"
}

data "archive_file" "zip" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${path.root}/build/${local.function_name}.zip"
}

resource "aws_sqs_queue" "dlq" {
  name                      = var.dlq_name
  message_retention_seconds = 1209600 # 14 days to investigate and replay
  sqs_managed_sse_enabled   = true
}

resource "aws_cloudwatch_log_group" "fn" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = 30
}

resource "aws_lambda_function" "trigger" {
  function_name    = local.function_name
  role             = var.role_arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.zip.output_path
  source_code_hash = data.archive_file.zip.output_base64sha256
  timeout          = 30 # the API replies 202 immediately
  memory_size      = 256

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = var.security_group_ids
  }

  environment {
    variables = {
      API_URL             = var.api_url
      API_TIMEOUT_SECONDS = "10"
    }
  }

  depends_on = [aws_cloudwatch_log_group.fn]
}

# S3 invokes Lambda asynchronously: these settings decide what happens on failure.
resource "aws_lambda_function_event_invoke_config" "trigger" {
  function_name                = aws_lambda_function.trigger.function_name
  maximum_retry_attempts       = 2
  maximum_event_age_in_seconds = 3600
  destination_config {
    on_failure {
      destination = aws_sqs_queue.dlq.arn
    }
  }
}

resource "aws_lambda_permission" "s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.trigger.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = var.bucket_arn
}

resource "aws_cloudwatch_metric_alarm" "dlq" {
  alarm_name          = "${local.function_name}-dlq-not-empty"
  alarm_description   = "A request could not be handed to the API after retries"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.dlq.name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [var.alarm_topic_arn]
}

resource "aws_cloudwatch_metric_alarm" "errors" {
  alarm_name          = "${local.function_name}-errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.trigger.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alarm_topic_arn]
}

output "function_arn" { value = aws_lambda_function.trigger.arn }
output "function_name" { value = aws_lambda_function.trigger.function_name }
output "dlq_url" { value = aws_sqs_queue.dlq.url }
output "s3_permission_id" { value = aws_lambda_permission.s3.id }
