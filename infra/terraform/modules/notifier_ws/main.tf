# Agreed step 7: S3 event on output/ -> notifier Lambda -> push to the UI over WebSocket.
# ASSUMED design (open question Q2): API Gateway WebSocket API + DynamoDB connection map.
variable "name_prefix" { type = string }
variable "env" { type = string }
variable "region" { type = string }
variable "ws_source_dir" { type = string }
variable "notifier_source_dir" { type = string }
variable "bucket_arn" { type = string }
variable "kms_key_arn" { type = string }
variable "alarm_topic_arn" { type = string }

resource "aws_dynamodb_table" "connections" {
  name         = "${var.name_prefix}-ws-connections"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "request_id"
  attribute {
    name = "request_id"
    type = "S"
  }
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }
  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_key_arn
  }
}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# ---------------------------------------------------------------- WebSocket API
resource "aws_apigatewayv2_api" "ws" {
  name                       = "${var.name_prefix}-results-ws"
  protocol_type              = "WEBSOCKET"
  route_selection_expression = "$request.body.action"
}

resource "aws_iam_role" "ws" {
  name               = "${var.name_prefix}-ws-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

resource "aws_iam_role_policy_attachment" "ws_logs" {
  role       = aws_iam_role.ws.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "ws" {
  role = aws_iam_role.ws.id
  name = "least-privilege"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "StoreSubscription", Effect = "Allow", Action = ["dynamodb:PutItem"], Resource = aws_dynamodb_table.connections.arn },
      { Sid = "UseTableKey", Effect = "Allow", Action = ["kms:Decrypt", "kms:GenerateDataKey"], Resource = var.kms_key_arn },
    ]
  })
}

data "archive_file" "ws" {
  type        = "zip"
  source_dir  = var.ws_source_dir
  output_path = "${path.root}/build/${var.name_prefix}-ws.zip"
}

resource "aws_lambda_function" "ws" {
  function_name    = "${var.name_prefix}-ws"
  role             = aws_iam_role.ws.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.ws.output_path
  source_code_hash = data.archive_file.ws.output_base64sha256
  timeout          = 10
  environment {
    variables = { CONNECTIONS_TABLE = aws_dynamodb_table.connections.name }
  }
}

resource "aws_apigatewayv2_integration" "ws" {
  api_id           = aws_apigatewayv2_api.ws.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.ws.invoke_arn
}

resource "aws_apigatewayv2_route" "routes" {
  for_each  = toset(["$connect", "$disconnect", "subscribe"])
  api_id    = aws_apigatewayv2_api.ws.id
  route_key = each.value
  target    = "integrations/${aws_apigatewayv2_integration.ws.id}"
}

resource "aws_apigatewayv2_stage" "ws" {
  api_id      = aws_apigatewayv2_api.ws.id
  name        = var.env
  auto_deploy = true
  default_route_settings {
    throttling_burst_limit = 50
    throttling_rate_limit  = 20
  }
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ws.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.ws.execution_arn}/*"
}

# ---------------------------------------------------------------- notifier Lambda
resource "aws_iam_role" "notifier" {
  name               = "${var.name_prefix}-notifier-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

resource "aws_iam_role_policy_attachment" "notifier_logs" {
  role       = aws_iam_role.notifier.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "notifier" {
  role = aws_iam_role.notifier.id
  name = "least-privilege"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "ReadResults", Effect = "Allow", Action = ["s3:GetObject"], Resource = "${var.bucket_arn}/output/*" },
      { Sid = "UseDataKey", Effect = "Allow", Action = ["kms:Decrypt"], Resource = var.kms_key_arn },
      { Sid = "Subscriptions", Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:DeleteItem"], Resource = aws_dynamodb_table.connections.arn },
      { Sid = "PushToUi", Effect = "Allow", Action = ["execute-api:ManageConnections"], Resource = "${aws_apigatewayv2_api.ws.execution_arn}/${var.env}/POST/@connections/*" },
    ]
  })
}

data "archive_file" "notifier" {
  type        = "zip"
  source_dir  = var.notifier_source_dir
  output_path = "${path.root}/build/${var.name_prefix}-notifier.zip"
}

resource "aws_lambda_function" "notifier" {
  function_name    = "${var.name_prefix}-notifier"
  role             = aws_iam_role.notifier.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.notifier.output_path
  source_code_hash = data.archive_file.notifier.output_base64sha256
  timeout          = 30
  environment {
    variables = {
      CONNECTIONS_TABLE = aws_dynamodb_table.connections.name
      WS_ENDPOINT       = replace(aws_apigatewayv2_stage.ws.invoke_url, "wss://", "https://")
    }
  }
}

resource "aws_lambda_permission" "s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.notifier.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = var.bucket_arn
}

resource "aws_cloudwatch_metric_alarm" "notifier_errors" {
  alarm_name          = "${var.name_prefix}-notifier-errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.notifier.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alarm_topic_arn]
}

output "ws_url" { value = aws_apigatewayv2_stage.ws.invoke_url }
output "notifier_function_arn" { value = aws_lambda_function.notifier.arn }
output "notifier_function_name" { value = aws_lambda_function.notifier.function_name }
output "s3_permission_id" { value = aws_lambda_permission.s3.id }
