# Package the app/ modules directly (no pip build, no S3 artifact). The Lambda
# python3.12 runtime bundles boto3, and the rest of the code is standard library.
data "archive_file" "lambda" {
  type        = "zip"
  output_path = "${path.module}/build/${var.resource_prefix}.zip"

  dynamic "source" {
    for_each = fileset("${path.module}/../lambda/app", "*.py")
    content {
      content  = file("${path.module}/../lambda/app/${source.value}")
      filename = "app/${source.value}"
    }
  }
}

# Egress only: nothing reaches the Lambda inbound. 443 covers SSM, CloudWatch
# Logs and the AI Guardrails ALB (through the VPC's NAT). 53 covers VPC DNS,
# which resolves the guardrails.aigw.internal private zone.
resource "aws_security_group" "lambda" {
  name        = "${var.resource_prefix}-lambda"
  description = "AI Guardrails webhook Lambda: egress only"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "HTTPS to AI Guardrails ALB, SSM, CloudWatch Logs"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "DNS (UDP) inside the VPC"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  egress {
    description = "DNS (TCP) inside the VPC"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }
}

resource "aws_cloudwatch_log_group" "webhook" {
  name              = "/aws/lambda/${var.resource_prefix}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "webhook" {
  function_name    = var.resource_prefix
  description      = "Anthropic Inference hooks -> Netskope AI Guardrails on Demand"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "app.handler.lambda_handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = var.lambda_timeout_seconds
  memory_size      = var.lambda_memory_mb

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      AIGD_URL                      = local.aigd_url
      AIGD_PROFILE_ID               = var.aigd_profile_id
      AIGD_TIMEOUT_SECONDS          = tostring(var.aigd_timeout_seconds)
      CA_PARAM_NAME                 = local.cert_parameter_name
      SIGNING_SECRET_PARAM          = aws_ssm_parameter.signing.name
      SIGNING_SECRET_PREVIOUS_PARAM = aws_ssm_parameter.signing_previous.name
      LOG_LEVEL                     = var.log_level
    }
  }

  lifecycle {
    precondition {
      condition     = var.lambda_timeout_seconds > var.aigd_timeout_seconds
      error_message = "lambda_timeout_seconds must be greater than aigd_timeout_seconds."
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.basic_logs,
    aws_iam_role_policy_attachment.vpc_access,
    aws_iam_role_policy.lambda_runtime,
    aws_cloudwatch_log_group.webhook,
    aws_route.private_nat,
  ]
}
