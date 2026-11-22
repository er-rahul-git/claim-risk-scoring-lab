"""CMS script: flags procedure codes on a (synthetic) high-scrutiny list."""

HIGH_SCRUTINY = {"99215", "99223", "99233", "93306", "70553", "J1745", "G0151", "97110"}


def run(claim: dict) -> dict:
    flagged = sorted(c for c in claim["procedure_codes"] if c in HIGH_SCRUTINY)
    risk = min(1.0, 0.3 * len(flagged) + 0.02 * len(claim["procedure_codes"]))
    return {"cms_risk": round(risk, 4), "flagged_codes": flagged, "code_count": len(claim["procedure_codes"])}
