# Non-prod: cheapest settings that still match the prod shape.
env                  = "nonprod"
region               = "ap-south-1"
repo                 = "YOUR_GITHUB_USER/claim-risk-scoring-lab"
vpc_cidr             = "10.50.0.0/16"
azs                  = ["ap-south-1a", "ap-south-1b"]
egress_mode          = "nat" # one NAT gateway; switch to "endpoints" to rehearse a no-internet VPC
force_destroy        = true  # lets `terraform destroy` empty the bucket
short_retention_days = 7
long_retention_days  = 30
instance_type        = "t3.small"
asg_min              = 1
asg_max              = 2
asg_desired          = 1
alarm_email          = "" # put your email here, then confirm the SNS subscription mail
