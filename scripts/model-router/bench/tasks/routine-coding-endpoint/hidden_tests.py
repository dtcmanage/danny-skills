import json
from pathlib import Path
from fastapi.testclient import TestClient
from pydantic import BaseModel
import answer
def test_endpoint():
    client = TestClient(answer.app)
    for item in json.loads(Path("input.json").read_text())["items"]:
        r = client.get(f"/items/{item['id']}")
        assert r.status_code == 200 and r.json() == item
    assert client.get("/items/999").status_code == 404
    assert client.get("/items/999").json() == {"detail":"Item not found"}
    assert client.get("/items/nope").status_code == 422
    schema = client.get("/openapi.json").json()
    model = schema["paths"]["/items/{item_id}"]["get"]["responses"]["200"]["content"]["application/json"]["schema"]
    assert model["$ref"].endswith("/Item")
    assert issubclass(answer.Item, BaseModel)
    assert answer.get_item.__annotations__.get("return") is not None
