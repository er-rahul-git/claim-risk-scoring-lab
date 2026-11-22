"""Composite score script (agreed step 6-7): weighted blend of the three script outputs."""


def run(composite_request: dict, weights: dict, thresholds: dict) -> dict:
    parts = {
        "provider": composite_request["provider"]["provider_risk"],
        "cms": composite_request["cms"]["cms_risk"],
        "payer": composite_request["payer"]["payer_risk"],
    }
    score = sum(weights[k] * v for k, v in parts.items()) / sum(weights.values())
    label = "HIGH" if score >= thresholds["high"] else "MEDIUM" if score >= thresholds["medium"] else "LOW"
    return {"composite_score": round(score, 4), "risk_label": label, "components": parts}
