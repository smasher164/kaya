import json
import re
import subprocess


def require_ios_sdk(binary, sdk_root, env=None):
    expected = json.loads((sdk_root / "SDKSettings.json").read_text(encoding="utf-8"))["Version"]
    got = subprocess.run(["xcrun", "vtool", "-show-build", str(binary)],
                         capture_output=True, text=True, encoding="utf-8", check=True, env=env)
    stamps = re.findall(r"platform\s+(\S+)\s+minos\s+(\S+)\s+sdk\s+(\S+)", got.stdout)
    if len(stamps) != 1 or stamps[0][0] != "IOSSIMULATOR" or stamps[0][2] != expected:
        raise ValueError(f"{binary}: built SDK stamp(s) {stamps}, expected IOSSIMULATOR SDK "
                         f"{expected} from {sdk_root}; compile through the guest compiler wrapper with "
                         "the selected -sdk and matching SDKROOT before staging")
    return stamps[0]
