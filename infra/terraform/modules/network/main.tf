# Private network for the API and the trigger Lambda. Nothing here is reachable from the internet.
# egress_mode:
#   "nat"       - one NAT gateway (cheapest for practice, ~1 NAT hour charge)
#   "endpoints" - no internet at all; AWS services reached through VPC endpoints (typical in enterprises)
variable "name" { type = string }
variable "region" { type = string }
variable "vpc_cidr" { type = string }
variable "azs" { type = list(string) }

variable "egress_mode" {
  type    = string
  default = "nat"
  validation {
    condition     = contains(["nat", "endpoints"], var.egress_mode)
    error_message = "egress_mode must be nat or endpoints."
  }
}

variable "endpoint_subnet_count" {
  description = "How many private subnets get interface endpoints (1 = cheaper, 2 = highly available)"
  type        = number
  default     = 1
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = var.name
  cidr = var.vpc_cidr
  azs  = var.azs

  # cidrsubnet(prefix, newbits, netnum): a /16 plus 8 bits = /24 subnets
  private_subnets = [for i, _ in var.azs : cidrsubnet(var.vpc_cidr, 8, i + 10)]
  public_subnets  = var.egress_mode == "nat" ? [for i, _ in var.azs : cidrsubnet(var.vpc_cidr, 8, i)] : []

  enable_nat_gateway   = var.egress_mode == "nat"
  single_nat_gateway   = true
  enable_dns_hostnames = true # required for private DNS on interface endpoints
  enable_dns_support   = true
}

# Gateway endpoint for S3 is free: S3 traffic never leaves the AWS network.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids
}

locals {
  interface_services = var.egress_mode == "endpoints" ? toset([
    "ssm", "ssmmessages", "ec2messages", "logs", "ecr.api", "ecr.dkr", "secretsmanager", "sts",
  ]) : toset([])
}

resource "aws_security_group" "endpoints" {
  count       = var.egress_mode == "endpoints" ? 1 : 0
  name        = "${var.name}-endpoints"
  description = "HTTPS from inside the VPC to AWS service endpoints"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
}

resource "aws_vpc_endpoint" "interface" {
  for_each            = local.interface_services
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = slice(module.vpc.private_subnets, 0, var.endpoint_subnet_count)
  security_group_ids  = [aws_security_group.endpoints[0].id]
  private_dns_enabled = true
}

output "vpc_id" { value = module.vpc.vpc_id }
output "private_subnet_ids" { value = module.vpc.private_subnets }
