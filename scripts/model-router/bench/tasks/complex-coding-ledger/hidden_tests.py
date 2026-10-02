import copy, json, random
from pathlib import Path
import pytest
from answer import post
ENTITIES = ("Alpha", "Beta", "Gamma")
def row(e, a, d, c): return dict(entity=e, account=a, debit=d, credit=c)
def test_fixture():
    rows = json.loads(Path("input.json").read_text())["entries"]
    before = copy.deepcopy(rows)
    got = post(rows)
    assert rows == before and set(got) == set(ENTITIES)
    for e in ENTITIES:
        amount = next(r["debit"] for r in rows if r["entity"] == e and r["debit"])
        assert got[e] == {"cash":amount, "capital":-amount}
def test_properties():
    rng = random.Random(7361)
    for _ in range(40):
        rows, want = [], {}
        for e in ENTITIES:
            a, b = rng.randrange(1, 1000000), rng.randrange(1, 1000000)
            rows += [row(e,"cash",a,0), row(e,"cash",b,0), row(e,"capital",0,a+b)]
            want[e] = {"cash":a+b, "capital":-a-b}
        shuffled = copy.deepcopy(rows); rng.shuffle(shuffled)
        assert post(rows) == want == post(shuffled)
    assert post([]) == {e:{} for e in ENTITIES}
    assert post([row("Alpha","cash",7,0),row("Alpha","capital",0,7)]) == {
        "Alpha":{"cash":7,"capital":-7},"Beta":{},"Gamma":{}}
@pytest.mark.parametrize("rows", [
    [row("Alpha","cash",3,0),row("Beta","capital",0,3)],
    [row("Alpha","cash",3,0)], [row("Delta","cash",1,0)],
    [row("Alpha","",1,0)], [row("Alpha","cash",True,0)],
    [row("Alpha","cash",1.5,0)], [row("Alpha","cash",-1,0)],
    [row("Alpha","cash",1,1)], [row("Alpha","cash",0,0)], [{}]])
def test_reject(rows):
    before = copy.deepcopy(rows)
    with pytest.raises(ValueError): post(rows)
    assert rows == before
