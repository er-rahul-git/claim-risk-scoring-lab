"""Payer script: payer denial history and billed-amount signal (synthetic)."""

DENIAL_RATES = {"MCR": 0.18, "MCD": 0.22, "BCBS": 0.12, "UHC": 0.10, "AETNA": 0.11}


def run(claim: dict) -> dict:
    payer = claim["payer_id"].upper()
    denial_rate = next((r for k, r in DENIAL_RATES.items() if payer.startswith(k)), 0.15)
    amount_factor = min(1.0, claim["billed_amount"] / 50000)
    risk = min(1.0, 0.6 * denial_rate / 0.25 + 0.4 * amount_factor)
    return {"payer_risk": round(risk, 4), "payer_denial_rate": denial_rate,
            "amount_factor": round(amount_factor, 4)}
