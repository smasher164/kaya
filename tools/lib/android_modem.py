"""The emulator's default network is the modem's, and a modem out of service is
named and set back to home through the console (docs/traps.md, the virtual WiFi
the host's load disconnected; and the modem a cold boot left out of service)."""
import re
import subprocess
import time

WALL_S = 30.0
REPAIR_AFTER_S = 3.0


def _out(argv):
    try:
        return subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                              encoding="utf-8", errors="replace", check=False,
                              timeout=20).stdout.replace("\r", "")
    except subprocess.TimeoutExpired:
        return ""


def modem_state(serial):
    """(down, what was read): the console's gsm voice/data and the phone's own registration."""
    console = _out(["adb", "-s", serial, "emu", "gsm", "status"])
    voice = re.search(r"gsm voice state:\s*(\S+)", console)
    data = re.search(r"gsm data state:\s*(\S+)", console)
    registry = _out(["adb", "-s", serial, "shell", "dumpsys", "telephony.registry"])
    state = re.search(r"mServiceState=\{mVoiceRegState=\d+\((\w+)\), mDataRegState=\d+\((\w+)\)",
                      registry)
    said = (f"console gsm voice {voice.group(1) if voice else '<unread>'}, data "
            f"{data.group(1) if data else '<unread>'}; phone voice "
            f"{state.group(1) if state else '<unread>'}, data "
            f"{state.group(2) if state else '<unread>'}")
    down = not (voice and data and state and voice.group(1) == data.group(1) == "home"
                and state.group(1) == state.group(2) == "IN_SERVICE")
    return down, said


def default_network(serial):
    dump = _out(["adb", "-s", serial, "shell", "dumpsys", "connectivity"])
    m = re.search(r"Active default network: (\d+)", dump)
    agent = ""
    if m:
        agent = next((ln for ln in dump.splitlines()
                      if f"NetworkAgentInfo{{network{{{m.group(1)}}}" in ln), "")
    wifi_on = _out(["adb", "-s", serial, "shell", "settings", "get", "global", "wifi_on"]).strip()
    seen = (f"wifi_on={wifi_on!r}, active default {m.group(1) if m else '<none>'}: "
            f"{agent[:80] if agent else '<no agent line>'}")
    return (wifi_on == "0" and "Transports: CELLULAR" in agent
            and re.search(r"ni\{MOBILE\[\w*\] CONNECTED", agent) is not None), seen


def modem_network(serial, label, wall=WALL_S, repair_after=REPAIR_AFTER_S):
    """(True, sentence) once the default network is cellular, else (False, sentence)."""
    subprocess.run(["adb", "-s", serial, "shell", "svc", "wifi", "disable"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    t0 = time.time()
    repaired = None
    while True:
        ok, seen = default_network(serial)
        took = time.time() - t0
        if ok:
            return True, (f"{label} ({serial}): network is the modem's ({seen})"
                          + (f"; the modem was repaired at {repaired[0]:.0f}s, when it read "
                             f"{repaired[1]}" if repaired else ""))
        if took > wall:
            break
        if repaired is None and took >= repair_after:
            down, said = modem_state(serial)
            if down:
                print(f"{label} ({serial}): the modem is down at {took:.0f}s ({said}); "
                      f"setting gsm voice and data home through the console", flush=True)
                for what in ("voice", "data"):
                    subprocess.run(["adb", "-s", serial, "emu", "gsm", what, "home"],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   check=False)
                repaired = (took, said)
        time.sleep(0.2)
    _down, now = modem_state(serial)
    return False, (f"{label} ({serial}): the default network is not the modem's after "
                   f"{took:.0f}s ({seen}); the modem reads {now} now, and "
                   + (f"was set home at {repaired[0]:.0f}s when it read {repaired[1]}"
                      if repaired else "read home and in service when checked, so it was not "
                      "repaired")
                   + " (the lane's fetches need the modem's network: docs/traps.md, the virtual "
                   "WiFi the host's load disconnected)")
