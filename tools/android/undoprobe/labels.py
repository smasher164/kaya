"""Print every visible label in a uiautomator dump (probe helper)."""
import re
import sys

xml = open(sys.argv[1], errors="replace").read()
labels = set(re.findall(r'text="([^"]+)"', xml))
labels |= set(re.findall(r'content-desc="([^"]+)"', xml))
print("labels on screen:", sorted(l for l in labels if l.strip()))
