# Deploy the Anthropic Inference hooks -> AI Guardrails on Demand stack.
#
# One run builds everything in AWS: VPC, NAT, internal ALB, the VPE appliance
# (Auto Scaling Group), private DNS, the self-signed ALB cert, the webhook Lambda,
# API Gateway, the API key, and the SSM parameters.
#
# Two steps stay manual because Netskope and Anthropic have no API for them.
# See docs/Deployment-Guide.docx for each.
#
#   1) ./deploy.ps1                       build the infrastructure
#   2) Activate the appliance in Netskope (enroll, service templates,
#      dataplane cert). Then create the AI Guardrails profile and copy its ID.
#   3) Configure the endpoint in Anthropic (URL + x-api-key from anthropic-setup.txt).
#      Anthropic then shows the whsec_ signing secret once.
#   4) Put the secret in .env as ANTHROPIC_SIGNING_SECRET and run ./deploy.ps1 again.
#
#   ./deploy.ps1 -PlanOnly     show the plan, change nothing
#   ./deploy.ps1 -Destroy      tear everything down (asks for confirmation)

param(
    [switch]$PlanOnly,
    [switch]$Destroy
)

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

if (-not (Test-Path .env)) {
    throw "No .env found. Copy .env.example to .env and fill it in first."
}

# Load .env (KEY=VALUE, '#' comments). Values are never echoed.
Get-Content .env | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith('#') -and $line.Contains('=')) {
        $k, $v = $line.Split('=', 2)
        Set-Item -Path "env:$($k.Trim())" -Value $v.Trim()
    }
}
if ($env:CA_BUNDLE) { $env:AWS_CA_BUNDLE = $env:CA_BUNDLE }

function Get-EnvOr([string]$name, [string]$default) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ($value) { return $value } else { return $default }
}

foreach ($required in 'AWS_REGION', 'GUARDRAILS_AMI_ID', 'GUARDRAILS_KEY_NAME', 'AIGD_PROFILE_ID') {
    if (-not [Environment]::GetEnvironmentVariable($required)) {
        throw "$required is not set in .env"
    }
}

$region = $env:AWS_REGION
$signingSecret = Get-EnvOr 'ANTHROPIC_SIGNING_SECRET' ''
$previousSecret = Get-EnvOr 'ANTHROPIC_SIGNING_SECRET_PREVIOUS' ''
foreach ($secret in @($signingSecret, $previousSecret)) {
    if ($secret -and -not $secret.StartsWith('whsec_')) {
        throw "Signing secrets must start with whsec_ (copy them exactly from Anthropic)."
    }
}

# --- Pre-flight: credentials, AMI and key pair ------------------------------
aws sts get-caller-identity --output text | Out-Null
if ($LASTEXITCODE -ne 0) { throw "AWS credentials not working. Check 'aws sts get-caller-identity'." }

$amiState = aws ec2 describe-images --region $region --image-ids $env:GUARDRAILS_AMI_ID `
    --query "Images[0].State" --output text
if ($amiState -ne 'available') {
    throw "AMI $($env:GUARDRAILS_AMI_ID) is not available in $region. Check the AMI ID and that Netskope shared it with this account."
}

aws ec2 describe-key-pairs --region $region --key-names $env:GUARDRAILS_KEY_NAME `
    --query "KeyPairs[0].KeyName" --output text | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Key pair '$($env:GUARDRAILS_KEY_NAME)' not found in $region."
}

# --- Map .env onto Terraform variables --------------------------------------
$env:TF_VAR_region = $region
$env:TF_VAR_guardrails_ami_id = $env:GUARDRAILS_AMI_ID
$env:TF_VAR_guardrails_key_name = $env:GUARDRAILS_KEY_NAME
$env:TF_VAR_aigd_profile_id = $env:AIGD_PROFILE_ID

# Source ranges for the API Gateway allowlist. ANTHROPIC_SOURCE_CIDRS is comma-separated.
# ANTHROPIC_SOURCE_CIDR (single value) is still read for older .env files.
$sourceCidrs = Get-EnvOr 'ANTHROPIC_SOURCE_CIDRS' (Get-EnvOr 'ANTHROPIC_SOURCE_CIDR' '160.79.106.0/24')
$cidrList = @($sourceCidrs.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$env:TF_VAR_source_cidrs = '["' + ($cidrList -join '","') + '"]'

$optional = @{
    'TF_VAR_vpc_cidr'                    = 'VPC_CIDR'
    'TF_VAR_additional_client_cidr'      = 'ADDITIONAL_CLIENT_CIDR'
    'TF_VAR_guardrails_name'             = 'GUARDRAILS_NAME'
    'TF_VAR_guardrails_instance_type'    = 'GUARDRAILS_INSTANCE_TYPE'
    'TF_VAR_guardrails_root_volume_gb'   = 'GUARDRAILS_ROOT_VOLUME_GB'
    'TF_VAR_guardrails_min_capacity'     = 'GUARDRAILS_MIN_CAPACITY'
    'TF_VAR_guardrails_desired_capacity' = 'GUARDRAILS_DESIRED_CAPACITY'
    'TF_VAR_guardrails_max_capacity'     = 'GUARDRAILS_MAX_CAPACITY'
    'TF_VAR_hosted_zone_name'            = 'HOSTED_ZONE_NAME'
    'TF_VAR_guardrails_domain_name'      = 'GUARDRAILS_DOMAIN_NAME'
    'TF_VAR_resource_prefix'             = 'RESOURCE_PREFIX'
    'TF_VAR_aigd_url'                    = 'AIGD_URL'
    'TF_VAR_aigd_timeout_seconds'        = 'AIGD_TIMEOUT_SECONDS'
    'TF_VAR_stage_name'                  = 'API_STAGE_NAME'
    'TF_VAR_throttle_rate_limit'         = 'THROTTLE_RATE_LIMIT'
    'TF_VAR_throttle_burst_limit'        = 'THROTTLE_BURST_LIMIT'
    'TF_VAR_lambda_timeout_seconds'      = 'LAMBDA_TIMEOUT_SECONDS'
    'TF_VAR_lambda_memory_mb'            = 'LAMBDA_MEMORY_MB'
    'TF_VAR_log_level'                   = 'LOG_LEVEL'
    'TF_VAR_log_retention_days'          = 'LOG_RETENTION_DAYS'
    'TF_VAR_permissions_boundary_arn'    = 'PERMISSIONS_BOUNDARY_ARN'
}
foreach ($target in $optional.Keys) {
    $value = [Environment]::GetEnvironmentVariable($optional[$target])
    if ($value) { [Environment]::SetEnvironmentVariable($target, $value) }
}

$tags = @{}
$tagMap = @{ Owner = 'TAG_OWNER'; ProjectType = 'TAG_PROJECT_TYPE'; CostCenter = 'TAG_COST_CENTER'; Stage = 'TAG_STAGE'; Sensitivity = 'TAG_SENSITIVITY' }
foreach ($key in $tagMap.Keys) {
    $value = [Environment]::GetEnvironmentVariable($tagMap[$key])
    if ($value) { $tags[$key] = $value }
}
if ($tags.Count -gt 0) {
    $env:TF_VAR_tags = ($tags | ConvertTo-Json -Compress)
}

# --- Terraform ----------------------------------------------------------------
Push-Location terraform
try {
    terraform init -input=false
    if ($LASTEXITCODE -ne 0) { throw "terraform init failed" }

    if ($Destroy) {
        terraform destroy -input=false
        if ($LASTEXITCODE -ne 0) { throw "terraform destroy failed" }
        return
    }

    terraform plan -input=false -out=tfplan
    if ($LASTEXITCODE -ne 0) { throw "terraform plan failed" }
    if ($PlanOnly) {
        Write-Host "Plan saved to terraform\tfplan. Nothing was applied." -ForegroundColor Yellow
        return
    }

    terraform apply -input=false tfplan
    if ($LASTEXITCODE -ne 0) { throw "terraform apply failed" }

    $signingParam = terraform output -raw signing_secret_parameter
    $previousParam = terraform output -raw signing_previous_parameter
    $webhookUrl = terraform output -raw webhook_url
    $apiKey = terraform output -raw api_key_header_value
    $guardrailsUrl = terraform output -raw guardrails_host_url
    $apiId = terraform output -raw api_gateway_id
    $apiRootResourceId = terraform output -raw api_root_resource_id
}
finally {
    Pop-Location
}

# Real signing secrets go to SSM, never into Terraform state or Lambda env.
if ($signingSecret) {
    aws ssm put-parameter --region $region --name $signingParam --type SecureString `
        --value $signingSecret --overwrite | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "could not write the signing secret to SSM" }
    Write-Host "Signing secret stored in SSM ($signingParam)." -ForegroundColor Green
}
else {
    # Not an error: the secret stored in SSM from an earlier run is kept as is.
    Write-Host "No ANTHROPIC_SIGNING_SECRET in .env this run. The value already in SSM is kept. If no secret was ever stored, requests fail signature checks until you add one and rerun." -ForegroundColor Cyan
}
if ($previousSecret) {
    aws ssm put-parameter --region $region --name $previousParam --type SecureString `
        --value $previousSecret --overwrite | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "could not write the previous signing secret to SSM" }
    Write-Host "Previous signing secret stored in SSM ($previousParam)." -ForegroundColor Green
}

# Health check through API Gateway's test invoke. A direct request from this
# computer is blocked by the source-IP allowlist (only 160.79.106.0/24 may call
# the webhook), so a direct call would fail here even when the webhook is healthy.
# Test invoke runs the same /healthz route and Lambda without the source-IP check.
$healthy = $false
$headersFile = Join-Path $env:TEMP 'anthropic-aigd-health-headers.json'
[IO.File]::WriteAllText($headersFile, (@{ 'x-api-key' = $apiKey } | ConvertTo-Json -Compress))
try {
    for ($attempt = 1; $attempt -le 5 -and -not $healthy; $attempt++) {
        $result = aws apigateway test-invoke-method --region $region --rest-api-id $apiId `
            --resource-id $apiRootResourceId --http-method GET --path-with-query-string /healthz `
            --headers "file://$($headersFile.Replace('\', '/'))" --query "[status,body]" --output text
        if ($LASTEXITCODE -eq 0 -and "$result" -match '^200') {
            $healthy = $true
        }
        else {
            Write-Host "health check attempt $attempt/5 did not return 200; retrying in 10s"
            Start-Sleep -Seconds 10
        }
    }
}
finally {
    Remove-Item $headersFile -Force -ErrorAction SilentlyContinue
}
if ($healthy) {
    Write-Host "Webhook health check passed (HTTP 200)." -ForegroundColor Green
}
else {
    Write-Host "Webhook health check did not pass. Check the Lambda logs in CloudWatch." -ForegroundColor Red
}

# Setup file for the Anthropic console. Holds the API key, so it is gitignored.
$setupFile = Join-Path $PSScriptRoot 'anthropic-setup.txt'
@"
Anthropic Inference hooks setup (generated by deploy.ps1)

Endpoint URL:
$webhookUrl

Custom request header (name / value):
x-api-key
$apiKey

Signing secret: copy the whsec_ value Anthropic shows when you save the endpoint,
put it in .env as ANTHROPIC_SIGNING_SECRET, then rerun ./deploy.ps1.

Keep this file private. It is gitignored.
"@ | Set-Content -Path $setupFile -Encoding utf8

Write-Host ""
Write-Host "Infrastructure is deployed." -ForegroundColor Cyan
Write-Host "Next (manual): activate the Guardrails appliance in Netskope, create the AI Guardrails profile,"
Write-Host "then configure Anthropic. Setup values: $setupFile"
Write-Host "Webhook URL:    $webhookUrl"
Write-Host "Guardrails URL: $guardrailsUrl (reachable inside the VPC after activation)"
