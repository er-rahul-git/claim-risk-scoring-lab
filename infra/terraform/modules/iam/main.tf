# Workload roles: one per component, least privilege. People never use these; humans get
# access through Identity Center (e.g. Entra ID PIM in many enterprises). ARNs are built from names so this module
# has no dependency loops with the modules that create the resources.
variable "name_prefix" { type = string }
variable "region" { type = string }
variable "account_id" { type = string }
variable "bucket_arn" { type = string }
variable "kms_key_arn" { type = string }
variable "ecr_repository_name" { type = string }
variable "image_tag_parameter_name" { type = string }
variable "api_log_group_name" { type = string }
variable "trigger_dlq_name" { type = string }

variable "arize_secret_name" {
  description = "Secrets Manager secret with Arize space_id/api_key; empty = no access"
  type        = string
  default     = ""
}

variable "permissions_boundary_arn" {
  description = "Optional boundary attached to every role (many enterprises require one)"
  type        = string
  default     = null
}

locals {
  ecr_arn   = "arn:aws:ecr:${var.region}:${var.account_id}:repository/${var.ecr_repository_name}"
  param_arn = "arn:aws:ssm:${var.region}:${var.account_id}:parameter${var.image_tag_parameter_name}"
  logs_arn  = "arn:aws:logs:${var.region}:${var.account_id}:log-group:${var.api_log_group_name}:*"
  dlq_arn   = "arn:aws:sqs:${var.region}:${var.account_id}:${var.trigger_dlq_name}"
  secret    = var.arize_secret_name == "" ? [] : ["arn:aws:secretsmanager:${var.region}:${var.account_id}:secret:${var.arize_secret_name}-*"]
}

# ---------------------------------------------------------------- API on EC2
data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "api" {
  name                 = "${var.name_prefix}-api-ec2"
  assume_role_policy   = data.aws_iam_policy_document.ec2_trust.json
  permissions_boundary = var.permissions_boundary_arn
}

resource "aws_iam_role_policy_attachment" "api_ssm" {
  role       = aws_iam_role.api.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" # Session Manager instead of SSH
}

data "aws_iam_policy_document" "api" {
  statement {
    sid       = "ReadRequests"
    actions   = ["s3:GetObject"]
    resources = ["${var.bucket_arn}/requests/*"]
  }
  statement {
    sid       = "WriteResults"
    actions   = ["s3:PutObject"]
    resources = ["${var.bucket_arn}/responses/*", "${var.bucket_arn}/output/*", "${var.bucket_arn}/errors/*"]
  }
  statement {
    sid       = "CheckIdempotency"
    actions   = ["s3:ListBucket"]
    resources = [var.bucket_arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["output/*"]
    }
  }
  statement {
    sid       = "UseDataKey"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.kms_key_arn]
  }
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"] # AWS only allows "*" for this action
    resources = ["*"]
  }
  statement {
    sid       = "PullImage"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
    resources = [local.ecr_arn]
  }
  statement {
    sid       = "ReadImageTag"
    actions   = ["ssm:GetParameter"]
    resources = [local.param_arn]
  }
  statement {
    sid       = "WriteLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [local.logs_arn]
  }
  dynamic "statement" {
    for_each = length(local.secret) > 0 ? [1] : []
    content {
      sid       = "ReadArizeSecret"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = local.secret
    }
  }
}

resource "aws_iam_role_policy" "api" {
  name   = "least-privilege"
  role   = aws_iam_role.api.id
  policy = data.aws_iam_policy_document.api.json
}

resource "aws_iam_instance_profile" "api" {
  name = "${var.name_prefix}-api-ec2"
  role = aws_iam_role.api.name
}

# ---------------------------------------------------------------- Trigger Lambda
data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "trigger" {
  name                 = "${var.name_prefix}-trigger-lambda"
  assume_role_policy   = data.aws_iam_policy_document.lambda_trust.json
  permissions_boundary = var.permissions_boundary_arn
}

resource "aws_iam_role_policy_attachment" "trigger_vpc" {
  role       = aws_iam_role.trigger.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole" # logs + ENIs
}

data "aws_iam_policy_document" "trigger" {
  statement {
    sid       = "SendFailuresToDlq" # needed for the on-failure destination
    actions   = ["sqs:SendMessage"]
    resources = [local.dlq_arn]
  }
  # Deliberately NO S3 access: the trigger only passes the path.
}

resource "aws_iam_role_policy" "trigger" {
  name   = "least-privilege"
  role   = aws_iam_role.trigger.id
  policy = data.aws_iam_policy_document.trigger.json
}

output "api_instance_profile_name" { value = aws_iam_instance_profile.api.name }
output "api_role_arn" { value = aws_iam_role.api.arn }
output "trigger_role_arn" { value = aws_iam_role.trigger.arn }
