# CLAUDE.md

Project instructions for coding agents working in this repository.

## What this is

A self-contained install of the Netskope **AI Guardrails on Demand** VPE
appliance plus a webhook that receives Anthropic **Inference hooks** and
inspects prompts and tool calls with it. One `terraform apply` builds the AWS
side. The Netskope and Anthropic steps are manual.

## Layout

| Path | Purpose |
|------|---------|
| `lambda/app/` | Webhook code. Standard library plus boto3 (bundled in the Lambda runtime). No third-party packages. |
| `lambda/tests/` | pytest suite. Run with `cd lambda && python -m pytest`. |
| `terraform/` | Everything in AWS: network, appliance ASG, ALB, DNS, cert, webhook, API Gateway. Local state. |
| `deploy.ps1` | Reads `.env`, runs Terraform, writes the signing secret to SSM, runs a health check. |
| `.env.example` | Every setting, with comments. Copy to `.env` (gitignored). |
| `docs/Deployment-Guide.docx` | Customer deployment guide. Keep it in step with the code. |
| `dlpod-appliance-webhook-terraform/` | A separate git repo (DLPoD webhook). Do not modify it from here. |

## Rules

1. **Never run `terraform apply` or `terraform destroy`, or any AWS command that
   changes resources.** Read-only checks (`plan`, `validate`, `fmt`, `output`,
   `describe-*`, `get-*`, `list-*`) are fine. The operator runs `deploy.ps1`.
2. **Never commit or print secrets.** `.env`, `anthropic-setup.txt`, state files,
   the signing secret (`whsec_...`), the API key value and the cert private key
   stay out of git. Signing secrets go to SSM SecureString, not Lambda env and
   not Terraform variables.
3. **Keep the Lambda dependency-free.** Anything beyond the standard library and
   boto3 needs a build step, which breaks the self-deploy goal.
4. **Fail closed with non-200.** A missing verdict, backend error, or bad
   signature returns a non-200 status, which Anthropic treats as a webhook failure
   so the organization's fail mode applies. Never signal a deny with an error
   status. A deny is `200 {"action": "deny", ...}`.
5. **Verify signatures before parsing.** Use `app/signing.py`. Keep the 300-second
   tolerance and constant-time comparison.
6. **Log metadata, never content.** Log request IDs, verdicts, categories and
   latency. Do not log prompt text or tool inputs.
7. **Lambda timeout must exceed the AI Guardrails client timeout.** Terraform
   enforces this with a precondition. Keep both below the verdict timeout set in
   Anthropic's Inference hooks settings.
8. **The appliance stack must match the tested design.** The network, ALB, ASG,
   and cert layout in `terraform/` mirror the reference CloudFormation template
   (`Guardrails/templates/guardrails-standalone.yaml`). Change them only on purpose.
9. **Anthropic's protocol may change** (the beta is documented as subject to
   change). Re-check field names against Anthropic's endpoint docs before changing
   `frames.py` or `handler.py`.
10. **Any change to `lambda/app/` must keep `python -m pytest` green.**
11. **Any change to the deployment steps must update the guide** in
    `docs/Deployment-Guide.docx`.

## Reference

- Anthropic: Inference hooks configuration and endpoint docs (platform.claude.com/docs/en/manage-claude/inference-hooks-*)
- AI Guardrails activation and verification: `Guardrails/README.md` ("After deployment", "Verify the service") and `Guardrails/HANDOVER-guardrails.md`
- Reference CloudFormation template: `Guardrails/templates/guardrails-standalone.yaml`
- DLPoD equivalent for comparison: `dlpod-appliance-webhook-terraform/AGENTS.md`
