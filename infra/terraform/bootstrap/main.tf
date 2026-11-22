# ONE-TIME setup per AWS account, run from your laptop (local state):
#   cd infra/terraform/bootstrap
#   AWS_PROFILE=crs-nonprod terraform init
#   AWS_PROFILE=crs-nonprod terraform apply -var env=nonprod -var github_repo=<you>/claim-risk-scoring-lab \
#     -var 'deploy_trusted_environments=["prod"]'
#   AWS_PROFILE=crs-prod    terraform apply -var env=prod    -var github_repo=<you>/claim-risk-scoring-lab
# Creates: the Terraform state bucket, the GitHub OIDC provider, and the two roles GitHub Actions uses.
# After this, nothing is applied from a laptop again - everything goes through pull requests.
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }
}

variable "env" { type = string }
variable "github_repo" {
  description = "owner/repo allowed to assume these roles"
  type        = string
}
variable "region" {
  type    = string
  default = "ap-south-1"
}
variable "deploy_trusted_environments" {
  description = "GitHub environments allowed to use the deploy role. In nonprod add \"prod\" so the prod job can PULL the proven image."
  type        = list(string)
  default     = []
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = "claim-risk-scoring", Environment = var.env, ManagedBy = "terraform-bootstrap" }
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  name_prefix = "crs-${var.env}"
}

# ---------------------------------------------------------------- state bucket
resource "aws_s3_bucket" "state" {
  bucket = "crs-tfstate-${var.env}-${local.account_id}"
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled" # lets you recover an older state if one gets corrupted
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------- GitHub OIDC
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "github_trust" {
  # Terraform role: only jobs running in THIS environment.
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Only jobs that declare `environment: <env>` in this repo can assume the role.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:environment:${var.env}"]
    }
  }
}

data "aws_iam_policy_document" "deploy_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [for e in distinct(concat([var.env], var.deploy_trusted_environments)) : "repo:${var.github_repo}:environment:${e}"]
    }
  }
}

# Runs terraform plan/apply. Broad on purpose for a practice account; at a company this
# would be narrower and carry a permissions boundary.
resource "aws_iam_role" "terraform" {
  name               = "crs-github-terraform-${var.env}"
  assume_role_policy = data.aws_iam_policy_document.github_trust.json
}

resource "aws_iam_role_policy_attachment" "terraform_admin" {
  role       = aws_iam_role.terraform.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# Deploys application code only: push an image, set the tag, roll the instances.
resource "aws_iam_role" "deploy" {
  name               = "crs-github-deploy-${var.env}"
  assume_role_policy = data.aws_iam_policy_document.deploy_trust.json
}

data "aws_iam_policy_document" "deploy" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "PushImage"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
    ]
    resources = ["arn:aws:ecr:${var.region}:${local.account_id}:repository/${local.name_prefix}-api"]
  }
  statement {
    sid       = "SetImageTag"
    actions   = ["ssm:PutParameter", "ssm:GetParameter"]
    resources = ["arn:aws:ssm:${var.region}:${local.account_id}:parameter/${local.name_prefix}/api/image_tag"]
  }
  statement {
    sid = "RollInstances"
    actions = [
      "autoscaling:StartInstanceRefresh",
      "autoscaling:DescribeInstanceRefreshes",
      "autoscaling:DescribeAutoScalingGroups",
    ]
    resources = ["*"]
  }
  statement {
    sid     = "SmokeTestBucket"
    actions = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
    resources = [
      "arn:aws:s3:::${local.name_prefix}-data-${local.account_id}",
      "arn:aws:s3:::${local.name_prefix}-data-${local.account_id}/*",
    ]
  }
  statement {
    sid       = "SmokeTestKey"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "deploy" {
  role   = aws_iam_role.deploy.id
  name   = "deploy-only"
  policy = data.aws_iam_policy_document.deploy.json
}

output "state_bucket" { value = aws_s3_bucket.state.bucket }
output "terraform_role_arn" { value = aws_iam_role.terraform.arn }
output "deploy_role_arn" { value = aws_iam_role.deploy.arn }