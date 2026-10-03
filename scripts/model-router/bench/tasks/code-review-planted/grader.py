"""Grade a structured correction using a bounded Boolean AST; never execute it."""
from __future__ import annotations

import ast
from itertools import product
from pathlib import Path
import re
import sys


def boolean(node: ast.AST, active: bool, banned: bool) -> bool:
    if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name):
        if node.value.id == "user" and node.attr in {"is_active", "is_banned"}:
            return active if node.attr == "is_active" else banned
    if isinstance(node, ast.Constant) and type(node.value) is bool:
        return node.value
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.Not):
        return not boolean(node.operand, active, banned)
    if isinstance(node, ast.BoolOp) and isinstance(node.op, (ast.And, ast.Or)):
        # Inspect every branch, even one that Python would short circuit.
        values = [boolean(value, active, banned) for value in node.values]
        return all(values) if isinstance(node.op, ast.And) else any(values)
    if isinstance(node, ast.Compare) and all(isinstance(op, (ast.Eq, ast.NotEq, ast.Is, ast.IsNot)) for op in node.ops):
        values = [boolean(value, active, banned) for value in [node.left, *node.comparators]]
        return all((left == right) if isinstance(op, (ast.Eq, ast.Is)) else (left != right)
                   for left, op, right in zip(values, node.ops, values[1:]))
    raise ValueError("Unsupported Boolean expression")


def grade(answer: str) -> bool:
    answer = answer.replace("\r\n", "\n").replace("\r", "\n")
    match = re.fullmatch(r"\s*LINE: 13[ \t]*\nFIX: ([^\n]+)\s*", answer)
    if match is None or len(match[1]) > 1000 or "#" in match[1]:
        return False
    try:
        tree = ast.parse(match[1].strip(), mode="eval")
        if sum(1 for _ in ast.walk(tree)) > 100:
            return False
        return all(boolean(tree.body, active, banned) == (active and not banned)
                   for active, banned in product((False, True), repeat=2))
    except (SyntaxError, ValueError, RecursionError):
        return False


if __name__ == "__main__":
    passed = grade(Path(sys.argv[1]).read_text(encoding="utf-8"))
    print("PASS" if passed else "FAIL")
    raise SystemExit(0 if passed else 1)
