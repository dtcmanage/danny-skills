import json,sys
try: ok=json.load(open(sys.argv[1]))=={"id":"R-104","owner":"Maya","amount":"USD 42.50"}
except Exception: ok=False
print("PASS" if ok else "FAIL");sys.exit(0 if ok else 1)
