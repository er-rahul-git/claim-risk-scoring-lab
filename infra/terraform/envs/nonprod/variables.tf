variable "env" {
  type = string
  validation {
    condition     = contains(["nonprod", "prod"], var.env)
    error_message = "env must be nonprod or prod."
  }
}
variable "region" {
  type    = string
  default = "ap-south-1"
}
variable "repo" {
  description = "GitHub owner/repo, used as a tag"
  type        = string
}
variable "vpc_cidr" { type = string }
variable "azs" { type = list(string) }
variable "egress_mode" {
  type    = string
  default = "nat"
}
variable "endpoint_subnet_count" {
  type    = number
  default = 1
}
variable "force_destroy" {
  type    = bool
  default = false
}
variable "short_retention_days" {
  type    = number
  default = 30
}
variable "long_retention_days" {
  type    = number
  default = 90
}
variable "instance_type" {
  type    = string
  default = "t3.small"
}
variable "asg_min" {
  type    = number
  default = 1
}
variable "asg_max" {
  type    = number
  default = 2
}
variable "asg_desired" {
  type    = number
  default = 1
}
variable "alarm_email" {
  type    = string
  default = ""
}
variable "arize_secret_name" {
  type    = string
  default = ""
}
variable "permissions_boundary_arn" {
  type    = string
  default = null
}
