import re,sys
s=open(sys.argv[1]).read().lower(); ok=bool(re.search(r"line\s*13",s)) and "banned" in s and "allow" in s and "or" in s
print("PASS" if ok else "FAIL");sys.exit(0 if ok else 1)
