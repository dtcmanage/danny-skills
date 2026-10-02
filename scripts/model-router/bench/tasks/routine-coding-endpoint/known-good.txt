from pathlib import Path
import json
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
class Item(BaseModel):
    id: int
    name: str
    quantity: int
app = FastAPI()
@app.get("/items/{item_id}", response_model=Item)
def get_item(item_id: int) -> Item:
    rows = json.loads(Path(__file__).with_name("input.json").read_text())["items"]
    for row in rows:
        if row["id"] == item_id:
            return Item(**row)
    raise HTTPException(status_code=404, detail="Item not found")
