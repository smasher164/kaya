import subprocess, sys, time
from mkscript import script
serial, loc, tag = sys.argv[1:4]
A=["adb","-s",serial]
subprocess.run(A+["logcat","-c"])
s=script()
args=A+["shell","am","start","-W","-n","dev.kaya.rusthost/.MainActivity","--es","KAYA_SELFTEST","numberfield",
        "--es","KAYA_SELFTEST_SCRIPT",f"'{s}'"]
if loc!="-": args+=["--es","KAYA_LOCALE",loc]
r=subprocess.run(args,capture_output=True,text=True)
print(r.stdout[-300:], r.stderr[-300:], flush=True)
deadline=time.time()+420
out=""
while time.time()<deadline:
    time.sleep(5)
    out=subprocess.run(A+["logcat","-d","-s","kaya:*"],capture_output=True,text=True,encoding="utf-8",errors="replace").stdout
    if "KAYA_SELFTEST:" in out: break
open(f"{tag}-logcat.txt","w",encoding="utf-8").write(out)
print("DONE", "KAYA_SELFTEST:" in out)
