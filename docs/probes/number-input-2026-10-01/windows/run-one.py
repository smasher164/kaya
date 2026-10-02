import subprocess, sys, time
tag, loc, mode = sys.argv[1:4]
H="akhil@192.168.64.2"
def ssh(c, t=40):
    return subprocess.run(["ssh","-o","BatchMode=yes",H,c],capture_output=True,text=True,timeout=t,encoding="utf-8",errors="replace")
ssh(f"del C:\\kaya\\nfprobe\\{tag}-out.txt 2>nul & exit /b 0")
r=ssh(f'schtasks /create /tn kaya_nfprobe /tr "C:\\kaya\\nfprobe\\run.cmd {tag} {loc} {mode}" /sc once /st 00:00 /it /rl highest /f >nul && schtasks /run /tn kaya_nfprobe')
print(r.stdout.strip(), r.stderr.strip())
for i in range(50):
    time.sleep(2)
    o=ssh(f"type C:\\kaya\\nfprobe\\{tag}-out.txt").stdout
    if "EXIT=" in o:
        break
print(o[-1500:])
subprocess.run(["scp","-q",f"{H}:C:/kaya/nfprobe/{tag}-vtrace.txt",f"{tag}-vtrace.txt"])
subprocess.run(["scp","-q",f"{H}:C:/kaya/nfprobe/{tag}-out.txt",f"{tag}-out.txt"])
