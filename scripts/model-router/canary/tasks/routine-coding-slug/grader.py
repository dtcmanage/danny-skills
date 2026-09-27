from pathlib import Path
import subprocess,sys,tempfile
with tempfile.TemporaryDirectory(prefix="router-canary-") as tmp:
 p=Path(tmp)
 (p/"answer.py").write_text(Path(sys.argv[1]).read_text(encoding="utf-8"),encoding="utf-8")
 (p/"test_hidden.py").write_text('import socket\ndef blocked(*args,**kwargs): raise RuntimeError("network disabled")\nsocket.socket.connect=blocked\nsocket.create_connection=blocked\nimport answer\ndef test_hidden():\n f=answer.slugify\n assert f(\' Hello, WORLD! \')==\'hello-world\'\n assert f(\'a__b  c\')==\'a-b-c\'\n',encoding="utf-8")
 try:
  result=subprocess.run([sys.executable,"-m","pytest","-q",str(p/"test_hidden.py")],cwd=p,capture_output=True,timeout=30)
  ok=result.returncode==0
 except subprocess.TimeoutExpired: ok=False
 print("PASS" if ok else "FAIL")
 sys.exit(0 if ok else 1)
