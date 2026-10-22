# ---------------------------------------------------------------------------
# General
# ---------------------------------------------------------------------------

variable "region" {
  type        = string
  description = "AWS region. The Netskope VPE AMI is shared in us-east-1."
  default     = "us-east-1"
}

variable "tags" {
  type        = map(string)
  description = "Extra tags merged onto every resource."
  default     = {}
}

# ---------------------------------------------------------------------------
# Network (created by this stack)
# ---------------------------------------------------------------------------

variable "vpc_cidr" {
  type        = string
  description = "CIDR for the new VPC (/16 to /22). Four /24 subnets are carved from it. Must not overlap networks you will peer with."
  default     = "10.5.0.0/16"

  validation {
    condition     = can(regex("^(\\d{1,3}\\.){3}\\d{1,3}/(1[6-9]|2[0-2])$", var.vpc_cidr))
    error_message = "vpc_cidr must be an IPv4 CIDR between /16 and /22."
  }
}

variable "additional_client_cidr" {
  type        = string
  description = "Optional extra CIDR (peered VPC, Transit Gateway or VPN) allowed to reach the ALB on 443 and the appliance on SSH 22. Empty = VPC CIDR only."
  default     = ""
}

# ---------------------------------------------------------------------------
# AI Guardrails on Demand (VPE) appliance
# ---------------------------------------------------------------------------

variable "guardrails_name" {
  type        = string
  description = "Name prefix for the Guardrails appliance stack resources. The cert parameter is /<guardrails_name>/guardrails-cert."
  default     = "netskope-guardrails"
}

variable "guardrails_ami_id" {
  type        = string
  description = "Netskope Virtual Private Edge (VPE) AMI ID for AI Guardrails on Demand. Shared with your account by Netskope. Must be in the deployment region."
}

variable "guardrails_key_name" {
  type        = string
  description = "Existing EC2 key pair in the region, used for SSH to the appliance as nsadmin (one-time VPE CLI activation step)."
}

variable "guardrails_instance_type" {
  type        = string
  description = "Instance type for the VPE appliance. General purpose, at least 8 vCPU and 32 GiB RAM. CPU only: GPU detection is a separate VM."
  default     = "m5.2xlarge"

  validation {
    condition     = contains(["m5.2xlarge", "m5.4xlarge", "m6i.2xlarge", "m6i.4xlarge"], var.guardrails_instance_type)
    error_message = "guardrails_instance_type must be one of m5.2xlarge, m5.4xlarge, m6i.2xlarge, m6i.4xlarge."
  }
}

variable "guardrails_root_volume_gb" {
  type        = number
  description = "Encrypted gp3 root volume size for the appliance, in GB."
  default     = 1024
}

variable "guardrails_api_port" {
  type        = number
  description = "Port the AI Guardrails on Demand API listens on (explicit-proxy mode). The ALB forwards HTTP to it."
  default     = 8080
}

variable "guardrails_health_check_path" {
  type        = string
  description = "ALB health check path for the appliance API."
  default     = "/"
}

variable "guardrails_min_capacity" {
  type    = number
  default = 1
}

variable "guardrails_desired_capacity" {
  type    = number
  default = 1
}

variable "guardrails_max_capacity" {
  type        = number
  description = "Maximum appliance instances (allows manual scale-out)."
  default     = 2
}

# ---------------------------------------------------------------------------
# DNS and certificate
# ---------------------------------------------------------------------------

variable "hosted_zone_name" {
  type        = string
  description = "Route 53 PRIVATE hosted zone created for the new VPC. Pick a different name if another VPC you connect already uses this zone name."
  default     = "aigw.internal"
}

variable "guardrails_domain_name" {
  type        = string
  description = "Internal FQDN clients use to reach the Guardrails ALB. Must be inside hosted_zone_name. The self-signed cert CN/SAN is this name."
  default     = "guardrails.aigw.internal"
}

# ---------------------------------------------------------------------------
# Webhook (Lambda + API Gateway)
# ---------------------------------------------------------------------------

variable "resource_prefix" {
  type        = string
  description = "Prefix for webhook resources and SSM parameter names."
  default     = "anthropic-aigd"
}

variable "aigd_url" {
  type        = string
  description = "AI Guardrails evaluation URL. Empty = https://<guardrails_domain_name>/api/v2/aiguardrails/evaluation."
  default     = ""
}

variable "aigd_profile_id" {
  type        = string
  description = "AI Guardrails profile ID to evaluate prompts against."
}

variable "aigd_timeout_seconds" {
  type        = number
  description = "Client-side timeout for the AI Guardrails call. Keep below the Anthropic verdict timeout."
  default     = 5
}

variable "source_cidrs" {
  type        = list(string)
  description = "Source blocks allowed to call the webhook. Keep Anthropic's 160.79.106.0/24. Add test addresses as /32 entries."
  default     = ["160.79.106.0/24"]
}

variable "stage_name" {
  type        = string
  description = "API Gateway stage name. The webhook URL is the stage invoke URL."
  default     = "prod"
}

variable "throttle_rate_limit" {
  type        = number
  description = "Usage plan steady-state requests per second. 0 disables throttling."
  default     = 0
}

variable "throttle_burst_limit" {
  type        = number
  description = "Usage plan burst limit. Only applied when throttle_rate_limit > 0."
  default     = 0
}

variable "lambda_timeout_seconds" {
  type        = number
  description = "Lambda timeout. Must exceed aigd_timeout_seconds."
  default     = 6
}

variable "lambda_memory_mb" {
  type        = number
  description = "Lambda memory size in MB."
  default     = 256
}

variable "log_level" {
  type        = string
  description = "Lambda log level (DEBUG, INFO, WARNING, ERROR)."
  default     = "INFO"
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch Logs retention for the webhook Lambda."
  default     = 30
}

variable "permissions_boundary_arn" {
  type        = string
  description = "Optional IAM permissions boundary for the webhook Lambda role. Empty = none. Some accounts require one."
  default     = ""
}
