import re
import sys


answer = open(sys.argv[1], encoding="utf-8").read().lower()
sentences = re.split(r"[.!?\n]+", answer)
line = re.compile(r"\bline\s+13\b")
approval = re.compile(r"\b(?:fine|correct|okay|ok|not\s+(?:a\s+)?problem)\b")
operator = re.compile(r"\bor\b")
wrong = re.compile(r"\b(?:wrong|incorrect|bug|instead|should|mistake|erroneous)\b")
lets_banned_through = re.compile(
    r"\b(?:allow|allows|allowed|allowing|lets|let)\s+(?:the\s+)?banned\s+users?\b"
    r"|\bbanned\s+users?\s+(?:are\s+|can\s+be\s+)?(?:allow|allows|allowed|allowing|lets|let)\b"
)

line_sentences = [sentence for sentence in sentences if line.search(sentence)]
reject = any(approval.search(sentence) for sentence in line_sentences)
ok = not reject and any(
    operator.search(sentence)
    and wrong.search(sentence)
    and lets_banned_through.search(sentence)
    for sentence in line_sentences
)
print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
