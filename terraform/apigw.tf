# Regional REST API in front of the Lambda. Two gates before any code runs:
#   1. Source IP must be inside one of var.source_cidrs (resource policy).
#   2. The x-api-key header must match a usage-plan key (Anthropic sends it as
#      a custom request header configured in the Inference hooks settings).
# The Lambda then checks the Standard Webhooks signature.

data "aws_iam_policy_document" "api_policy" {
  statement {
    sid       = "AllowAll"
    effect    = "Allow"
    actions   = ["execute-api:Invoke"]
    resources = ["execute-api:/*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
  }

  statement {
    sid       = "DenyOutsideAnthropic"
    effect    = "Deny"
    actions   = ["execute-api:Invoke"]
    resources = ["execute-api:/*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "NotIpAddress"
      variable = "aws:SourceIp"
      values   = var.source_cidrs
    }
  }
}

resource "aws_api_gateway_rest_api" "webhook" {
  name        = var.resource_prefix
  description = "Anthropic Inference hooks endpoint for AI Guardrails on Demand"

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  policy = data.aws_iam_policy_document.api_policy.json
}

resource "aws_api_gateway_method" "root" {
  rest_api_id      = aws_api_gateway_rest_api.webhook.id
  resource_id      = aws_api_gateway_rest_api.webhook.root_resource_id
  http_method      = "ANY"
  authorization    = "NONE"
  api_key_required = true
}

resource "aws_api_gateway_resource" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.webhook.id
  parent_id   = aws_api_gateway_rest_api.webhook.root_resource_id
  path_part   = "{proxy+}"
}

resource "aws_api_gateway_method" "proxy" {
  rest_api_id      = aws_api_gateway_rest_api.webhook.id
  resource_id      = aws_api_gateway_resource.proxy.id
  http_method      = "ANY"
  authorization    = "NONE"
  api_key_required = true

  request_parameters = {
    "method.request.path.proxy" = true
  }
}

resource "aws_api_gateway_integration" "root" {
  rest_api_id             = aws_api_gateway_rest_api.webhook.id
  resource_id             = aws_api_gateway_rest_api.webhook.root_resource_id
  http_method             = aws_api_gateway_method.root.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.webhook.invoke_arn
}

resource "aws_api_gateway_integration" "proxy" {
  rest_api_id             = aws_api_gateway_rest_api.webhook.id
  resource_id             = aws_api_gateway_resource.proxy.id
  http_method             = aws_api_gateway_method.proxy.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.webhook.invoke_arn
}

resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.webhook.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.webhook.execution_arn}/*/*"
}

# Redeploy when anything that changes the API surface changes. Hash the INPUTS
# (our policy document, CIDR, code hash), never read-back attributes: AWS
# normalises policy JSON and that would force a redeploy on every plan.
resource "aws_api_gateway_deployment" "webhook" {
  rest_api_id = aws_api_gateway_rest_api.webhook.id

  triggers = {
    redeployment = sha1(jsonencode([
      data.aws_iam_policy_document.api_policy.json,
      var.source_cidrs,
      data.archive_file.lambda.output_base64sha256,
      aws_api_gateway_method.root.api_key_required,
      aws_api_gateway_method.proxy.api_key_required,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_api_gateway_method.root,
    aws_api_gateway_method.proxy,
    aws_api_gateway_integration.root,
    aws_api_gateway_integration.proxy,
  ]
}

resource "aws_api_gateway_stage" "webhook" {
  rest_api_id   = aws_api_gateway_rest_api.webhook.id
  deployment_id = aws_api_gateway_deployment.webhook.id
  stage_name    = var.stage_name
}

resource "aws_api_gateway_api_key" "anthropic" {
  name    = "${var.resource_prefix}-anthropic"
  enabled = true
}

resource "aws_api_gateway_usage_plan" "anthropic" {
  name = "${var.resource_prefix}-anthropic"

  api_stages {
    api_id = aws_api_gateway_rest_api.webhook.id
    stage  = aws_api_gateway_stage.webhook.stage_name
  }

  dynamic "throttle_settings" {
    for_each = var.throttle_rate_limit > 0 ? [1] : []
    content {
      rate_limit  = var.throttle_rate_limit
      burst_limit = var.throttle_burst_limit
    }
  }
}

resource "aws_api_gateway_usage_plan_key" "anthropic" {
  key_id        = aws_api_gateway_api_key.anthropic.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.anthropic.id
}
