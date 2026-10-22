output "webhook_url" {
  description = "Paste into Anthropic's Inference hooks endpoint URL field."
  value       = aws_api_gateway_stage.webhook.invoke_url
}

output "api_key_header_value" {
  description = "Paste into a custom request header named x-api-key in Anthropic's Inference hooks settings."
  value       = aws_api_gateway_api_key.anthropic.value
  sensitive   = true
}

output "signing_secret_parameter" {
  description = "SSM parameter that deploy.ps1 writes the whsec_ signing secret into."
  value       = aws_ssm_parameter.signing.name
}

output "signing_previous_parameter" {
  description = "SSM parameter for the previous signing secret during rotation."
  value       = aws_ssm_parameter.signing_previous.name
}

output "lambda_function_name" {
  value = aws_lambda_function.webhook.function_name
}

output "guardrails_alb_dns_name" {
  description = "Internal DNS name of the AI Guardrails ALB (VPC only)."
  value       = aws_lb.guardrails.dns_name
}

output "guardrails_host_url" {
  description = "Guardrails host URL. Works only once the appliance is activated."
  value       = "https://${var.guardrails_domain_name}"
}

output "guardrails_cert_parameter" {
  description = "SSM parameter with the ALB certificate PEM. Clients pin it."
  value       = aws_ssm_parameter.guardrails_cert.name
}

output "guardrails_asg_name" {
  value = aws_autoscaling_group.guardrails.name
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "aigd_url" {
  value = local.aigd_url
}

output "api_gateway_id" {
  description = "REST API ID. deploy.ps1 uses it for the health check."
  value       = aws_api_gateway_rest_api.webhook.id
}

output "api_root_resource_id" {
  description = "Root resource ID of the REST API. deploy.ps1 uses it for the health check."
  value       = aws_api_gateway_rest_api.webhook.root_resource_id
}
