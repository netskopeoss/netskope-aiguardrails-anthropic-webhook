"""Environment-driven configuration for the Anthropic -> AI Guardrails webhook.

Every value comes from a Lambda environment variable that Terraform sets from
the operator's .env (see terraform/lambda.tf). Nothing secret lives here: the
signing secret and the TLS CA are read from SSM Parameter Store at runtime.
"""
from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    # Full URL of the AI Guardrails on Demand evaluation endpoint (internal ALB).
    aigd_url: str
    # Profile ID sent as profiles["ai-guardrails"][0]. Tenant-specific, from .env.
    aigd_profile_id: str
    # Client-side budget for the AI Guardrails call. Must stay below the
    # verdict timeout configured in Anthropic's Inference hooks settings.
    aigd_timeout_seconds: float
    # SSM parameter holding the self-signed CA PEM for the AI Guardrails ALB.
    ca_parameter_name: str
    # SSM SecureString holding the current whsec_ signing secret.
    signing_secret_parameter_name: str
    # Optional SSM SecureString holding the previous secret, accepted during rotation.
    previous_signing_secret_parameter_name: str | None
    log_level: str


def load_settings() -> Settings:
    previous = os.environ.get("SIGNING_SECRET_PREVIOUS_PARAM", "").strip()
    return Settings(
        aigd_url=os.environ["AIGD_URL"],
        aigd_profile_id=os.environ["AIGD_PROFILE_ID"],
        aigd_timeout_seconds=float(os.environ.get("AIGD_TIMEOUT_SECONDS", "5")),
        ca_parameter_name=os.environ["CA_PARAM_NAME"],
        signing_secret_parameter_name=os.environ["SIGNING_SECRET_PARAM"],
        previous_signing_secret_parameter_name=previous or None,
        log_level=os.environ.get("LOG_LEVEL", "INFO").upper(),
    )
