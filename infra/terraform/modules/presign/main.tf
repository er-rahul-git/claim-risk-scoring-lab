# Agreed step 1 for a browser UI: a tiny Lambda behind a Function URL hands out a 5-minute
# presigned PUT URL for requests/<id>.json. The browser never holds AWS credentials.
# NOTE: authorization_type = "NONE" is fine for practice; a real UI would sit behind SSO/Cognito.
variable "name_prefix" { type = string }
variable "source_dir" { type = string }
variable "bucket_name" { type = string }
variable "bucket_arn" { type = string }
variable "kms_key_arn" { type = string }
variable "allowed_origins" {
  description = "Browser origins allowed to call the Function URL"
  type        = list(string)
}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "presign" {
  name               = "${var.name_prefix}-presign-lambda"
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

resource "aws_iam_role_policy_attachment" "logs" {
  role       = aws_iam_role.presign.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "presign" {
  role = aws_iam_role.presign.id
  name = "least-privilege"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # The URL can only ever write new requests - never read, never other prefixes.
      { Sid = "WriteRequestsOnly", Effect = "Allow", Action = ["s3:PutObject"], Resource = "${var.bucket_arn}/requests/*" },
      { Sid = "EncryptWithDataKey", Effect = "Allow", Action = ["kms:GenerateDataKey"], Resource = var.kms_key_arn },
    ]
  })
}

data "archive_file" "zip" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${path.root}/build/${var.name_prefix}-presign.zip"
}

resource "aws_lambda_function" "presign" {
  function_name    = "${var.name_prefix}-presign"
  role             = aws_iam_role.presign.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.zip.output_path
  source_code_hash = data.archive_file.zip.output_base64sha256
  timeout          = 10
  environment {
    variables = { BUCKET = var.bucket_name }
  }
}

resource "aws_lambda_function_url" "presign" {
  function_name      = aws_lambda_function.presign.function_name
  authorization_type = "NONE"
  cors {
    allow_origins = var.allowed_origins
    allow_methods = ["GET"]
    max_age       = 300
  }
}

output "presign_url" { value = aws_lambda_function_url.presign.function_url }
