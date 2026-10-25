# commit messages of the postgres repo (all refs) -> COPY text file: n \t hash \t message
import subprocess, sys
out = open(sys.argv[2], "w", encoding="utf-8")
raw = subprocess.run(["git", "--git-dir", sys.argv[1], "log", "--all", "--format=%H%x01%B%x02"],
                     capture_output=True, check=True).stdout.decode("utf-8", "replace")
n = 0
for rec in raw.split("\x02"):
    rec = rec.strip("\n")
    if not rec:
        continue
    h, _, msg = rec.partition("\x01")
    msg = msg.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n").replace("\r", "\\r").replace("\x00", "")
    n += 1
    out.write(f"{n}\t{h.strip()}\t{msg}\n")
out.close()
print("ROWS", n)
