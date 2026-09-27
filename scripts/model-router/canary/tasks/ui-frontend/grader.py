from html.parser import HTMLParser
import sys
class P(HTMLParser):
 def __init__(self): super().__init__(); self.tags=[]
 def handle_starttag(self,t,a): self.tags.append((t,dict(a)))
p=P();p.feed(open(sys.argv[1]).read());ts=p.tags
ok=any(t=="form" for t,a in ts) and any(t=="label" and a.get("for")=="email" for t,a in ts) and any(t=="input" and a.get("id")=="email" and a.get("type")=="email" and "required" in a for t,a in ts) and any(t=="button" and a.get("type")=="submit" for t,a in ts)
print("PASS" if ok else "FAIL");sys.exit(0 if ok else 1)
