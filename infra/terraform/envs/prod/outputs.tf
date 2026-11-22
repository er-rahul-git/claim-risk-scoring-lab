output "bucket_name" { value = module.storage.bucket_name }
output "api_url_internal" { value = module.api_ec2.api_url }
output "ecr_repository_url" { value = module.api_ec2.ecr_repository_url }
output "asg_name" { value = module.api_ec2.asg_name }
output "image_tag_parameter" { value = module.api_ec2.image_tag_parameter_name }
output "websocket_url" { value = module.notifier_ws.ws_url }
output "trigger_dlq_url" { value = module.lambda_trigger.dlq_url }
output "alerts_topic_arn" { value = module.observability.alerts_topic_arn }
