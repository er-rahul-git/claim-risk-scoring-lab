# Risk Scoring API: Docker on EC2 in an Auto Scaling group behind an INTERNAL load balancer.
# Only resources holding the "client" security group (the trigger Lambda) can reach it.
variable "name_prefix" { type = string }
variable "env" { type = string }
variable "region" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "instance_profile_name" { type = string }
variable "bucket_name" { type = string }
variable "ecr_repository_name" { type = string }
variable "image_tag_parameter_name" { type = string }
variable "log_group_name" { type = string }
variable "log_retention_days" {
  type    = number
  default = 30
}
variable "instance_type" {
  type    = string
  default = "t3.small"
}
variable "min_size" {
  type    = number
  default = 1
}
variable "max_size" {
  type    = number
  default = 2
}
variable "desired_capacity" {
  type    = number
  default = 1
}

# ---------------------------------------------------------------- image registry + deployed tag
resource "aws_ecr_repository" "api" {
  name                 = var.ecr_repository_name
  image_tag_mutability = "IMMUTABLE" # a tag (git SHA) can never point to different code
  force_delete         = var.env != "prod"
  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "api" {
  repository = aws_ecr_repository.api.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep the last 20 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 20 }
      action       = { type = "expire" }
    }]
  })
}

# The pipeline writes the git SHA here, then starts an instance refresh. New instances read it at boot.
resource "aws_ssm_parameter" "image_tag" {
  name  = var.image_tag_parameter_name
  type  = "String"
  value = "not-deployed-yet"
  lifecycle {
    ignore_changes = [value] # owned by deploy.yml after creation
  }
}

resource "aws_cloudwatch_log_group" "api" {
  name              = var.log_group_name
  retention_in_days = var.log_retention_days
}

# ---------------------------------------------------------------- security groups
resource "aws_security_group" "client" {
  name        = "${var.name_prefix}-api-client"
  description = "Attach to anything allowed to call the API (the trigger Lambda)"
  vpc_id      = var.vpc_id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-api-alb"
  description = "Internal ALB: HTTP only from API clients"
  vpc_id      = var.vpc_id
  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.client.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "api" {
  name        = "${var.name_prefix}-api"
  description = "API instances: 8080 only from the ALB, no SSH"
  vpc_id      = var.vpc_id
  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------------------------------------------------------------- compute
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_launch_template" "api" {
  name_prefix            = "${var.name_prefix}-api-"
  image_id               = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  vpc_security_group_ids = [aws_security_group.api.id]

  iam_instance_profile {
    name = var.instance_profile_name
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 2          # lets the container reach instance credentials
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 20
      volume_type = "gp3"
      encrypted   = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tftpl", {
    region              = var.region
    env                 = var.env
    bucket              = var.bucket_name
    log_group           = aws_cloudwatch_log_group.api.name
    repository_url      = aws_ecr_repository.api.repository_url
    registry            = split("/", aws_ecr_repository.api.repository_url)[0]
    image_tag_parameter = aws_ssm_parameter.image_tag.name
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.name_prefix}-api" }
  }
}

resource "aws_lb" "api" {
  name               = "${var.name_prefix}-api"
  internal           = true
  load_balancer_type = "application"
  subnets            = var.private_subnet_ids
  security_groups    = [aws_security_group.alb.id]
}

resource "aws_lb_target_group" "api" {
  name                 = "${var.name_prefix}-api"
  port                 = 8080
  protocol             = "HTTP"
  vpc_id               = var.vpc_id
  deregistration_delay = 30
  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.api.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

resource "aws_autoscaling_group" "api" {
  name                      = "${var.name_prefix}-api"
  vpc_zone_identifier       = var.private_subnet_ids
  min_size                  = var.min_size
  max_size                  = var.max_size
  desired_capacity          = var.desired_capacity
  target_group_arns         = [aws_lb_target_group.api.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 180

  launch_template {
    id      = aws_launch_template.api.id
    version = aws_launch_template.api.latest_version
  }

  # Zero-downtime deploys: new instances must pass /health before old ones are removed.
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 100
      max_healthy_percentage = 200
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.name_prefix}-api"
    propagate_at_launch = true
  }
}

output "api_url" { value = "http://${aws_lb.api.dns_name}/audit" }
output "client_security_group_id" { value = aws_security_group.client.id }
output "ecr_repository_url" { value = aws_ecr_repository.api.repository_url }
output "asg_name" { value = aws_autoscaling_group.api.name }
output "image_tag_parameter_name" { value = aws_ssm_parameter.image_tag.name }
output "alb_arn_suffix" { value = aws_lb.api.arn_suffix }
output "target_group_arn_suffix" { value = aws_lb_target_group.api.arn_suffix }
