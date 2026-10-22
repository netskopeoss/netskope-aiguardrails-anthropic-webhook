data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id

  # Two AZs, same as the reference architecture: 2 public + 2 private /24s.
  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  vpc_prefix_bits = tonumber(split("/", var.vpc_cidr)[1])
  subnet_newbits  = 24 - local.vpc_prefix_bits

  public_subnet_cidrs  = [cidrsubnet(var.vpc_cidr, local.subnet_newbits, 0), cidrsubnet(var.vpc_cidr, local.subnet_newbits, 1)]
  private_subnet_cidrs = [cidrsubnet(var.vpc_cidr, local.subnet_newbits, 2), cidrsubnet(var.vpc_cidr, local.subnet_newbits, 3)]

  # Cert parameter follows the same naming as the CloudFormation stack, so the
  # webhook's CA parameter default matches on a fresh install.
  cert_parameter_name = "/${var.guardrails_name}/guardrails-cert"

  aigd_url = var.aigd_url != "" ? var.aigd_url : "https://${var.guardrails_domain_name}/api/v2/aiguardrails/evaluation"

  alb_client_cidrs = var.additional_client_cidr != "" ? [var.vpc_cidr, var.additional_client_cidr] : [var.vpc_cidr]

  tags = merge(
    {
      Project   = "netskope-aiguardrails-anthropic-webhook"
      ManagedBy = "terraform"
    },
    var.tags,
  )
}

locals {
  vpc_id                  = aws_vpc.main.id
  signing_parameter_name  = "/${var.resource_prefix}/signing-secret"
  previous_parameter_name = "/${var.resource_prefix}/signing-secret-previous"
}
