# Alerts topic + API health alarm + one dashboard per environment.
variable "name_prefix" { type = string }
variable "region" { type = string }
variable "alarm_email" {
  type    = string
  default = ""
}
variable "alb_arn_suffix" { type = string }
variable "target_group_arn_suffix" { type = string }
variable "trigger_function_name" { type = string }
variable "notifier_function_name" { type = string }

resource "aws_sns_topic" "alerts" {
  name              = "${var.name_prefix}-alerts"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email" # confirm the subscription from the email AWS sends
  endpoint  = var.alarm_email
}

resource "aws_cloudwatch_metric_alarm" "api_unhealthy" {
  alarm_name          = "${var.name_prefix}-api-unhealthy-hosts"
  alarm_description   = "At least one API instance is failing /health"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  dimensions          = { LoadBalancer = var.alb_arn_suffix, TargetGroup = var.target_group_arn_suffix }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.name_prefix}-claim-risk-scoring"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title  = "Lambda invocations and errors"
          region = var.region
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", var.trigger_function_name],
            ["AWS/Lambda", "Errors", "FunctionName", var.trigger_function_name],
            ["AWS/Lambda", "Invocations", "FunctionName", var.notifier_function_name],
            ["AWS/Lambda", "Errors", "FunctionName", var.notifier_function_name],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title  = "API: requests, 5xx, healthy hosts"
          region = var.region
          period = 300
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix, { stat = "Sum" }],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", var.alb_arn_suffix, { stat = "Sum" }],
            ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", var.target_group_arn_suffix, "LoadBalancer", var.alb_arn_suffix, { stat = "Minimum" }],
          ]
        }
      },
    ]
  })
}

output "alerts_topic_arn" { value = aws_sns_topic.alerts.arn }
