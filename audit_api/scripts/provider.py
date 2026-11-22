"""Provider script: risk signal about the billing provider (synthetic)."""
import hashlib


def run(claim: dict) -> dict:
    # Deterministic pseudo-history per provider NPI (stands in for a real provider-history lookup).
    digest = int(hashlib.sha256(claim["provider_npi"].encode()).hexdigest(), 16)
    prior_audits = digest % 6
    prior_findings = digest % (prior_audits + 1)
    risk = min(1.0, 0.12 * prior_audits + 0.15 * prior_findings)
    return {"provider_risk": round(risk, 4), "prior_audits": prior_audits, "prior_findings": prior_findings}
