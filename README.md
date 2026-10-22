# Anthropic Inference hooks → Netskope AI Guardrails on Demand

A self-contained install. One Terraform run builds the AWS side of the whole
path: the VPC, the Netskope VPE appliance, an internal load balancer, private
DNS, the webhook Lambda, and API Gateway. The Anthropic side is configured in
claude.ai.

**Full instructions for customers: [docs/Deployment-Guide.docx](docs/Deployment-Guide.docx).**
This README is the short reference for the repo.

```
Claude (Anthropic) ──HTTPS POST──▶ API Gateway (REGIONAL)
                                    │  source IP ∈ 160.79.106.0/24
                                    │  x-api-key (usage plan)
                                    ▼
                               Lambda (python3.12, in the new VPC)
                                    │  Standard Webhooks signature check
                                    │  extract text (prompt / tool call)
                                    ▼
                               Internal ALB (HTTPS 443, self-signed cert)
                                    │
                                    ▼
                               VPE appliance (ASG, AI Guardrails on Demand)
                                    │  Match / Not Match
                                    ▼
                    200 {"action": "allow"} or {"action": "deny", "deny_reason", "reference_id"}
```

Failures (bad signature, backend down, missing config) return a non-200 status.
Anthropic treats that as a webhook failure and applies the fail mode set in its
settings.

## What Terraform builds

| Area | Resources |
|------|-----------|
| Network | VPC, internet gateway, 2 public and 2 private subnets, one NAT gateway, route tables, S3 endpoint (`terraform/network.tf`) |
| Appliance | Launch template, Auto Scaling Group (EC2 health check), encrypted gp3 root, IMDSv2 (`terraform/guardrails_appliance.tf`) |
| Load balancer | Internal ALB, target group, HTTPS 443 listener, security groups (`terraform/guardrails_appliance.tf`) |
| DNS and certificate | Private Route 53 zone, A record, self-signed cert imported to ACM, cert PEM in SSM (`terraform/guardrails_cert.tf`) |
| Webhook | Lambda, IAM role, security group, log group, REST API with IP allowlist, API key, usage plan, stage, SSM parameters (`terraform/lambda.tf`, `apigw.tf`, `iam.tf`, `ssm.tf`) |

## What stays manual

These steps have no API, so no script can do them. The guide covers each one.

1. Get the VPE AMI ID and an EC2 key pair from Netskope (AMI shared with your account).
2. Create an AI Guardrails profile in the Netskope UI and copy its ID.
3. Activate the appliance after `terraform apply`: enroll the node, attach the platform and service templates, generate the dataplane cert.
4. Configure Anthropic Inference hooks in claude.ai (Owner or Primary owner role).

## Quick start

```powershell
Copy-Item .env.example .env        # fill in AMI, key pair, profile ID
./deploy.ps1 -PlanOnly             # review
./deploy.ps1                       # build
```

Then follow the guide for activation, Anthropic setup, and the signing-secret step.
`deploy.ps1` writes `anthropic-setup.txt` (the URL and API key). It is gitignored.

## Configuration

Everything is in `.env`. See `.env.example` for the full list. Required values:

| Setting | Notes |
|---------|-------|
| `AWS_REGION` | Must match the region the AMI is shared in |
| `GUARDRAILS_AMI_ID` | VPE appliance AMI, shared by Netskope |
| `GUARDRAILS_KEY_NAME` | Existing EC2 key pair in the region |
| `AIGD_PROFILE_ID` | AI Guardrails profile to evaluate against |

## Tests

```powershell
cd lambda
python -m pip install pytest
python -m pytest
```

The suite covers signature verification (rotation, tolerance, case-insensitive
headers), frame text extraction, the AI Guardrails client, and handler status codes.

## Behavior

| Frame | Inspected | Verdict |
|-------|-----------|---------|
| `prompt` | Every message: text, tool results, attachment text, tool-call names and inputs | Match → deny with categories in `deny_reason`; Not Match → allow |
| `tool_call` | The latest assistant message only | Same mapping |
| Other `type` | Not inspected | Allow, with a warning logged |
| No inspectable text | Not sent to AI Guardrails | Allow |

`reference_id` is the Anthropic `request_id` with characters outside
`[A-Za-z0-9._:/-]` removed, capped at 50 characters.

## Limits and known gaps

- **Request size.** API Gateway caps request bodies at 10 MB. The protocol
  allows up to 64 MiB. Larger prompts hit the fail mode.
- **Appliance activation** is a manual, Beta process. Until it is done the
  evaluation endpoint does not answer. The webhook's `/healthz` still responds.
- **Certificate expiry.** The self-signed ALB cert is valid for one year from the first apply. Renewal is not automated yet. Plan it before the expiry date.
- **Cold starts.** The first request after an idle period can be slow. Measure
  p95 in shadow mode before enforcing.
- **Protocol.** Anthropic's Inference hooks are in beta and field names may
  change. Re-check `lambda/app/frames.py` and `handler.py` when that happens.
- **State.** Terraform state is local and holds secrets (the cert key, the API
  key value). Keep the `terraform/` folder private, or move the state to a
  protected backend before sharing the repo.

## Teardown

```powershell
./deploy.ps1 -Destroy
```

The appliance is removed with everything else. Netskope's tenant still lists the
node, so remove it in the Netskope UI too.

## Files

| Path | What |
|------|------|
| `deploy.ps1` | Plan, deploy, destroy, secret and health-check flow |
| `.env.example` | Settings template |
| `docs/Deployment-Guide.docx` | Customer deployment guide (manual steps, tests, troubleshooting) |
| `lambda/app/` | Webhook code |
| `lambda/tests/` | pytest suite |
| `terraform/` | All AWS resources |
| `CLAUDE.md` | Rules for coding agents |
