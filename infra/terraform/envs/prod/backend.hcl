# Created once by infra/terraform/bootstrap (see README). One state file per environment.
bucket       = "crs-tfstate-prod-YOUR_PROD_ACCOUNT_ID"
key          = "claim-risk-scoring/terraform.tfstate"
region       = "ap-south-1"
encrypt      = true
use_lockfile = true # S3-native locking (Terraform >= 1.10), no DynamoDB table needed
