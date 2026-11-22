# One KMS key + one bucket. The bucket is the message bus and the audit trail:
# requests/ -> responses/{provider,cms,payer}/ -> output/ (+ errors/).
variable "name_prefix" { type = string }
variable "account_id" { type = string }

variable "force_destroy" {
  description = "true in non-prod so `terraform destroy` can empty the bucket"
  type        = bool
  default     = false
}

variable "short_retention_days" {
  description = "requests/ and responses/"
  type        = number
  default     = 30
}

variable "cors_allowed_origins" {
  description = "Browser origins allowed to PUT to presigned URLs (the UI). Empty = no CORS."
  type        = list(string)
  default     = []
}

variable "long_retention_days" {
  description = "output/ and errors/"
  type        = number
  default     = 90
}

resource "aws_kms_key" "data" {
  description             = "${var.name_prefix} data key (bucket, logs, queues)"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

resource "aws_kms_alias" "data" {
  name          = "alias/${var.name_prefix}-data"
  target_key_id = aws_kms_key.data.key_id
}

resource "aws_s3_bucket" "data" {
  bucket        = "${var.name_prefix}-data-${var.account_id}" # account id keeps the global name unique
  force_destroy = var.force_destroy
}

resource "aws_s3_bucket_ownership_controls" "data" {
  bucket = aws_s3_bucket.data.id
  rule {
    object_ownership = "BucketOwnerEnforced" # no ACLs, IAM decides everything
  }
}

resource "aws_s3_bucket_public_access_block" "data" {
  bucket                  = aws_s3_bucket.data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "data" {
  bucket = aws_s3_bucket.data.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  bucket = aws_s3_bucket.data.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.data.arn
    }
    bucket_key_enabled = true # fewer KMS calls = lower cost
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "data" {
  bucket = aws_s3_bucket.data.id

  dynamic "rule" {
    for_each = {
      requests  = var.short_retention_days
      responses = var.short_retention_days
      output    = var.long_retention_days
      errors    = var.long_retention_days
    }
    content {
      id     = "expire-${rule.key}"
      status = "Enabled"
      filter {
        prefix = "${rule.key}/"
      }
      expiration {
        days = rule.value
      }
      noncurrent_version_expiration {
        noncurrent_days = 7
      }
    }
  }
}

resource "aws_s3_bucket_cors_configuration" "ui" {
  count  = length(var.cors_allowed_origins) > 0 ? 1 : 0
  bucket = aws_s3_bucket.data.id
  cors_rule {
    allowed_methods = ["PUT"]
    allowed_origins = var.cors_allowed_origins
    allowed_headers = ["content-type", "x-amz-server-side-encryption"]
    max_age_seconds = 300
  }
}

data "aws_iam_policy_document" "tls_only" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    resources = [aws_s3_bucket.data.arn, "${aws_s3_bucket.data.arn}/*"]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "data" {
  bucket     = aws_s3_bucket.data.id
  policy     = data.aws_iam_policy_document.tls_only.json
  depends_on = [aws_s3_bucket_public_access_block.data]
}

output "bucket_name" { value = aws_s3_bucket.data.bucket }
output "bucket_arn" { value = aws_s3_bucket.data.arn }
output "kms_key_arn" { value = aws_kms_key.data.arn }
