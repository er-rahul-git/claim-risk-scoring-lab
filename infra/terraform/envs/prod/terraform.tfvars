# Prod: same modules as non-prod. Every difference from nonprod/terraform.tfvars is
# intentional and is exactly what the prod review looks at.
env                   = "prod"
region                = "ap-south-1"
repo                  = "YOUR_GITHUB_USER/claim-risk-scoring-lab"
vpc_cidr              = "10.60.0.0/16"
azs                   = ["ap-south-1a", "ap-south-1b"]
egress_mode           = "endpoints" # no internet path at all
endpoint_subnet_count = 2           # endpoints in both AZs
force_destroy         = false       # protect data
short_retention_days  = 30
long_retention_days   = 90
instance_type         = "t3.medium"
asg_min               = 2 # one per AZ
asg_max               = 4
asg_desired           = 2
alarm_email           = ""
