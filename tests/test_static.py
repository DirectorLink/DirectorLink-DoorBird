"""Static checks of the assembled Lua (offline).   python tests/test_static.py

- The source has no character outside Latin-1 (the controller's Lua and the test
  runtime read it the same).
- Every C4 call sits inside a pcall: Director raises on bad arguments, and a raise
  must never stop the driver. A small Lua scan takes out comments and strings, tracks
  the blocks (function / if / do / repeat ... end / until) and marks each
  `pcall(function()` block.
- With luac 5.1 (luac5.1 / luac on PATH): the driver compiles, and every global it
  reads is defined. A global that is read but never defined is a bug that only shows
  when that line runs: a typo, or a function that calls a `local` declared further
  down the file (Lua then looks up a global of that name, which is nil).
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

from harness import ROOT, check, finish

sys.path.insert(0, os.path.join(ROOT, "tools"))
import build  # noqa: E402

# Provided by Lua 5.1 or by Director at run time
RUNTIME = {
    "C4", "Properties", "print", "pairs", "ipairs", "next", "type", "tostring", "tonumber", "pcall", "error", "select",
    "setmetatable", "getmetatable", "rawget", "rawset", "unpack", "string", "table", "math", "os", "collectgarbage", "bit",
    "DIT_ADDING", "assert", "loadstring",
}
# Entry points Director calls
ENTRY_POINTS = {"OnDriverInit", "OnDriverLateInit", "OnDriverDestroyed", "OnDriverRemovedFromProject", "OnPropertyChanged",
                "ReceivedFromProxy", "UIRequest", "ExecuteCommand", "TestCondition", "GetCommandParamList",
                "GetNotificationAttachmentURL", "GetNotificationAttachmentBytes", "FinishedWithNotificationAttachment"}
NL = "\n"


def strip_lua(text):
    """Comments and strings out (strings become ""), line breaks kept."""
    out, i, n = [], 0, len(text)
    while i < n:
        if text.startswith("--[[", i) or text.startswith("--[==[", i):
            close = "]]" if text.startswith("--[[", i) else "]==]"
            j = text.find(close, i)
            j = n if j < 0 else j + len(close)
            out.append(NL * text.count(NL, i, j))
            i = j
        elif text.startswith("--", i):
            j = text.find(NL, i)
            i = n if j < 0 else j
        elif text[i] in "\"'":
            q, j = text[i], i + 1
            while j < n and text[j] != q:
                j += 2 if text[j] == "\\" else 1
            out.append('""')
            i = j + 1
        elif text.startswith("[[", i):
            j = text.find("]]", i)
            j = n if j < 0 else j + 2
            out.append('""' + NL * text.count(NL, i, j))
            i = j
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def luac():
    for name in ("luac5.1", "luac5.1.exe", "luac"):
        p = shutil.which(name)
        if p:
            return p
    local = os.path.join(os.path.expanduser("~"), "AppData", "Local", "Programs", "lua51", "luac5.1.exe")
    return local if os.path.exists(local) else None


src = build.assemble_lua("test")
lines = src.splitlines()
bad = sorted({c for c in src if ord(c) > 255})
check(not bad, f"the Lua source is Latin-1 only {bad}")

code = strip_lua(src)
check(code.count(NL) == src.count(NL), "the scan keeps the line numbers")
stack, unguarded = [], []
tokens = [t.group(0) for t in re.finditer(r"[A-Za-z_][A-Za-z0-9_]*|\(|:|\n", code)]
line = 1
for k, w in enumerate(tokens):
    if w == NL:
        line += 1
        continue
    if w in ("function", "if", "do", "repeat"):
        prev = [x for x in tokens[max(0, k - 3):k] if x != NL]
        stack.append(w == "function" and prev[-2:] == ["pcall", "("])
    elif w in ("end", "until"):
        if stack:
            stack.pop()
    elif w == "C4" and k + 1 < len(tokens) and tokens[k + 1] == ":":
        if not any(stack):
            unguarded.append(f"{line}: {lines[line - 1].strip()[:80]}")
check(not stack, "the scan closes every block")
check(not unguarded, f"every C4 call is guarded by pcall {unguarded[:6]}")

LUAC = luac()
if not LUAC:
    print("SKIP luac 5.1 not found (install lua5.1)")
    finish()

with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False, encoding="utf-8") as f:
    f.write(src)
    path = f.name
try:
    out = subprocess.run([LUAC, "-p", "-l", path], capture_output=True, text=True, encoding="utf-8", errors="replace")
finally:
    os.unlink(path)
check(out.returncode == 0, f"compiles with Lua 5.1 {out.stderr.strip()[:300]}")
gets, sets = {}, set()
for row in out.stdout.splitlines():
    m = re.search(r"\[(\d+)\]\s+(GETGLOBAL|SETGLOBAL)\s+.*;\s*(\S+)", row)
    if m:
        name = m.group(3)
        if m.group(2) == "GETGLOBAL":
            gets.setdefault(name, int(m.group(1)))
        else:
            sets.add(name)
undefined = sorted(n for n in gets if n not in sets and n not in RUNTIME)
detail = [f"{n} (line {gets[n]}: {lines[gets[n] - 1].strip()[:70]})" for n in undefined]
check(not undefined, f"every global it reads is defined {detail or ''}")
defined = sorted(n for n in sets if n in ENTRY_POINTS)
check(set(defined) == ENTRY_POINTS, f"defines the DriverWorks entry points ({len(defined)} of {len(ENTRY_POINTS)}: missing {sorted(ENTRY_POINTS - set(defined))})")

finish()
