# Signing secrets live in SSM SecureString, never in Lambda env or tfvars.
# Terraform creates the parameters with a placeholder; deploy.ps1 writes the
# real whsec_ value. ignore_changes stops later applies from reverting it.
#
# The placeholder is not a valid whsec_ value, so until it is replaced every
# request fails signature verification and gets a non-200 (fail mode applies).

resource "aws_ssm_parameter" "signing" {
  name        = local.signing_parameter_name
  description = "Anthropic Inference hooks signing secret (whsec_...). Set by deploy.ps1."
  type        = "SecureString"
  value       = "NOT-SET-run-deploy-script"

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "signing_previous" {
  name        = local.previous_parameter_name
  description = "Previous Anthropic signing secret, accepted during rotation. Optional."
  type        = "SecureString"
  value       = "NOT-SET-run-deploy-script"

  lifecycle {
    ignore_changes = [value]
  }
}
