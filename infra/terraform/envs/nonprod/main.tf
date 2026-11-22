# One environment = these modules wired together. prod/main.tf is identical; only
# terraform.tfvars and backend.hcl differ. That is what makes prod a "replica".
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
  backend "s3" {} # values in backend.hcl: terraform init -backend-config=backend.hcl
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project     = "claim-risk-scoring"
      Environment = var.env
      ManagedBy   = "terraform"
      Repo        = var.repo
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  name_prefix   = "crs-${var.env}"
  account_id    = data.aws_caller_identity.current.account_id
  repo_root     = abspath("${path.root}/../../../..")
  ecr_repo_name = "${local.name_prefix}-api"
  image_tag_ssm = "/${local.name_prefix}/api/image_tag"
  api_log_group = "/crs/${var.env}/api"
  dlq_name      = "${local.name_prefix}-trigger-dlq"
}

module "network" {
  source                = "../../modules/network"
  name                  = "${local.name_prefix}-vpc"
  region                = var.region
  vpc_cidr              = var.vpc_cidr
  azs                   = var.azs
  egress_mode           = var.egress_mode
  endpoint_subnet_count = var.endpoint_subnet_count
}

module "storage" {
  source               = "../../modules/storage"
  name_prefix          = local.name_prefix
  account_id           = local.account_id
  force_destroy        = var.force_destroy
  short_retention_days = var.short_retention_days
  long_retention_days  = var.long_retention_days
}

module "iam" {
  source                   = "../../modules/iam"
  name_prefix              = local.name_prefix
  region                   = var.region
  account_id               = local.account_id
  bucket_arn               = module.storage.bucket_arn
  kms_key_arn              = module.storage.kms_key_arn
  ecr_repository_name      = local.ecr_repo_name
  image_tag_parameter_name = local.image_tag_ssm
  api_log_group_name       = local.api_log_group
  trigger_dlq_name         = local.dlq_name
  arize_secret_name        = var.arize_secret_name
  permissions_boundary_arn = var.permissions_boundary_arn
}

module "api_ec2" {
  source                   = "../../modules/api_ec2"
  name_prefix              = local.name_prefix
  env                      = var.env
  region                   = var.region
  vpc_id                   = module.network.vpc_id
  private_subnet_ids       = module.network.private_subnet_ids
  instance_profile_name    = module.iam.api_instance_profile_name
  bucket_name              = module.storage.bucket_name
  ecr_repository_name      = local.ecr_repo_name
  image_tag_parameter_name = local.image_tag_ssm
  log_group_name           = local.api_log_group
  instance_type            = var.instance_type
  min_size                 = var.asg_min
  max_size                 = var.asg_max
  desired_capacity         = var.asg_desired
}

module "observability" {
  source                  = "../../modules/observability"
  name_prefix             = local.name_prefix
  region                  = var.region
  alarm_email             = var.alarm_email
  alb_arn_suffix          = module.api_ec2.alb_arn_suffix
  target_group_arn_suffix = module.api_ec2.target_group_arn_suffix
  trigger_function_name   = "${local.name_prefix}-trigger"
  notifier_function_name  = "${local.name_prefix}-notifier"
}

module "lambda_trigger" {
  source             = "../../modules/lambda_trigger"
  name_prefix        = local.name_prefix
  source_dir         = "${local.repo_root}/lambdas/trigger"
  role_arn           = module.iam.trigger_role_arn
  subnet_ids         = module.network.private_subnet_ids
  security_group_ids = [module.api_ec2.client_security_group_id]
  api_url            = module.api_ec2.api_url
  bucket_arn         = module.storage.bucket_arn
  dlq_name           = local.dlq_name
  alarm_topic_arn    = module.observability.alerts_topic_arn
}

module "notifier_ws" {
  source              = "../../modules/notifier_ws"
  name_prefix         = local.name_prefix
  env                 = var.env
  region              = var.region
  ws_source_dir       = "${local.repo_root}/lambdas/ws"
  notifier_source_dir = "${local.repo_root}/lambdas/notifier"
  bucket_arn          = module.storage.bucket_arn
  kms_key_arn         = module.storage.kms_key_arn
  alarm_topic_arn     = module.observability.alerts_topic_arn
}

# The event wiring (agreed steps 2 and 7). Lives here because it joins storage and both Lambdas.
# Only requests/ and output/ trigger anything, so writes to responses/ can never cause a loop.
resource "aws_s3_bucket_notification" "flow" {
  bucket = module.storage.bucket_name

  lambda_function {
    lambda_function_arn = module.lambda_trigger.function_arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "requests/"
    filter_suffix       = ".json"
  }

  lambda_function {
    lambda_function_arn = module.notifier_ws.notifier_function_arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "output/"
    filter_suffix       = ".json"
  }

  depends_on = [module.lambda_trigger, module.notifier_ws]
}
