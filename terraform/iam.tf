data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name                 = "${var.resource_prefix}-lambda"
  assume_role_policy   = data.aws_iam_policy_document.lambda_assume.json
  permissions_boundary = var.permissions_boundary_arn != "" ? var.permissions_boundary_arn : null
}

resource "aws_iam_role_policy_attachment" "basic_logs" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Creates and deletes the ENIs the Lambda uses inside the Guardrails VPC.
resource "aws_iam_role_policy_attachment" "vpc_access" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "lambda_runtime" {
  statement {
    sid     = "ReadWebhookParameters"
    actions = ["ssm:GetParameter"]
    resources = [
      "arn:${local.partition}:ssm:${var.region}:${local.account_id}:parameter${local.signing_parameter_name}",
      "arn:${local.partition}:ssm:${var.region}:${local.account_id}:parameter${local.previous_parameter_name}",
      "arn:${local.partition}:ssm:${var.region}:${local.account_id}:parameter${local.cert_parameter_name}",
    ]
  }

  # Decrypting SecureString values with the AWS-managed aws/ssm key, only via SSM.
  statement {
    sid       = "DecryptViaSsm"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "lambda_runtime" {
  name   = "${var.resource_prefix}-runtime"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_runtime.json
}
