def post(entries: list[dict]) -> dict[str, dict[str, int]]:
    balances = {e: {} for e in ("Alpha", "Beta", "Gamma")}
    for row in entries:
        try:
            e, a, d, c = (row[k] for k in ("entity", "account", "debit", "credit"))
            if e not in balances or not isinstance(a, str) or not a.strip():
                raise ValueError("invalid entity/account")
            if type(d) is not int or type(c) is not int or min(d, c) < 0 or (d > 0) == (c > 0):
                raise ValueError("invalid posting")
            balances[e][a] = balances[e].get(a, 0) + d - c
        except (KeyError, TypeError) as exc:
            raise ValueError("invalid row") from exc
    if any(sum(b.values()) for b in balances.values()):
        raise ValueError("unbalanced entity")
    return balances
