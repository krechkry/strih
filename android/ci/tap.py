#!/usr/bin/env python3
"""Taps the first on-screen element whose text or content description matches (uiautomator dump)."""
import re, subprocess, sys, time
want = sys.argv[1]
for attempt in range(5):
    subprocess.run(["adb", "shell", "uiautomator", "dump", "/sdcard/ui.xml"], capture_output=True)
    xml = subprocess.run(["adb", "exec-out", "cat", "/sdcard/ui.xml"], capture_output=True, text=True).stdout
    # a system "isn't responding" dialog (the emulator's launcher, not us) sits over the app: let it wait
    if "isn't responding" in xml or "isn&apos;t responding" in xml:
        w = re.search(r'<node [^>]*text="Wait"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', xml)
        if w:
            subprocess.run(["adb", "shell", "input", "tap", str((int(w.group(1)) + int(w.group(3))) // 2), str((int(w.group(2)) + int(w.group(4))) // 2)])
            print("dismissed a system 'not responding' dialog")
            time.sleep(1)
            continue
    for m in re.finditer(r'<node [^>]*>', xml):
        n = m.group(0)
        t = re.search(r' text="([^"]*)"', n); d = re.search(r'content-desc="([^"]*)"', n)
        if (t and t.group(1) == want) or (d and d.group(1) == want):
            b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', n)
            x = (int(b.group(1)) + int(b.group(3))) // 2; y = (int(b.group(2)) + int(b.group(4))) // 2
            subprocess.run(["adb", "shell", "input", "tap", str(x), str(y)])
            print(f"tapped {want!r} at {x},{y}")
            sys.exit(0)
    time.sleep(1)
print(f"not found: {want!r}")
sys.exit(1)
