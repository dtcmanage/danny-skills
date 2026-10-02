import re
import sys

# Judge the whole answer, not one sentence: a correct review may name the line,
# the operator, and the consequence in separate sentences. Reject an answer that
# approves line 13, or blames another line for the bug.
answer = open(sys.argv[1], encoding="utf-8").read().lower()
sentences = re.split(r"[.!?\n]+", answer)
line = re.compile(r"\bline\s+13\b")
other_line = re.compile(r"\bline\s+(?!13\b)\d+\b")
approval = re.compile(r"\b(?:fine|correct|okay|ok|not\s+(?:a\s+)?problem)\b")
blame = re.compile(r"\b(?:bug|defect|problem|issue|wrong|actual)\b")
operator = re.compile(r"\bor\b")
wrong = re.compile(r"\b(?:wrong|incorrect|bug|instead|should|mistake|erroneous|defect|flaw)\b")
article = r"(?:a\s+|the\s+|any\s+|all\s+|every\s+)?"
lets_banned_through = re.compile(
    r"\b(?:allow|allows|allowed|allowing|let|lets|letting|grant|grants|granting|granted|admit|admits|pass|passes)\s+"
    r"(?:access\s+(?:to|for)\s+)?" + article + r"banned\s+(?:user|users|account|accounts|people)\b"
    r"|\bbanned\s+(?:user|users|account|accounts|people)\s+(?:are\s+|is\s+|can\s+be\s+|get|gets|still\s+)?\s*"
    r"(?:allow|allows|allowed|allowing|let|lets|granted|admitted|pass|passes|passed|through|in|access)\b"
)

line_sentences = [s for s in sentences if line.search(s)]
names_line = bool(line_sentences)
approves = any(approval.search(s) for s in line_sentences)
blames_other = any(other_line.search(s) and blame.search(s) for s in sentences)
ok = (
    names_line
    and not approves
    and not blames_other
    and operator.search(answer)
    and wrong.search(answer)
    and lets_banned_through.search(answer)
)
print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
