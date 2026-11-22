from audit_api.scripts import cms, composite, payer, provider


def test_scripts_are_deterministic_and_bounded(valid_request):
    claim = valid_request["claim"]
    for mod, key in ((provider, "provider_risk"), (cms, "cms_risk"), (payer, "payer_risk")):
        a, b = mod.run(claim), mod.run(claim)
        assert a == b
        assert 0 <= a[key] <= 1


def test_cms_flags_high_scrutiny_codes(valid_request):
    assert cms.run(valid_request["claim"])["flagged_codes"] == ["93306", "99215"]


def test_composite_labels():
    w = {"provider": 0.4, "cms": 0.35, "payer": 0.25}
    t = {"high": 0.7, "medium": 0.4}
    req = lambda p, c, y: {"provider": {"provider_risk": p}, "cms": {"cms_risk": c}, "payer": {"payer_risk": y}}  # noqa: E731
    assert composite.run(req(0.9, 0.9, 0.9), w, t)["risk_label"] == "HIGH"
    assert composite.run(req(0.5, 0.5, 0.5), w, t)["risk_label"] == "MEDIUM"
    assert composite.run(req(0.1, 0.1, 0.1), w, t)["risk_label"] == "LOW"
