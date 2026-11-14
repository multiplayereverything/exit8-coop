"""Condense a UE4SS_ObjectDump.txt into a per-class summary of members and functions (with parameters).

Usage: python -I tools/dump_classes.py <UE4SS_ObjectDump.txt> <out.txt> [path prefix, default /Game/_Exit8/]
Locals of Blueprint functions (CallFunc_*, K2Node_*, Temp_*) are left out. Output stays in private/ (game data).
"""
import re, sys
from collections import defaultdict, OrderedDict

dump, out = sys.argv[1], sys.argv[2]
prefix = sys.argv[3] if len(sys.argv) > 3 else "/Game/_Exit8/"
line_re = re.compile(r"^\[[0-9A-F]+\] (\w+) (\S+)(.*)$")
skip = re.compile(r"^(CallFunc_|K2Node_|Temp_|LocalVar|UberGraphFrame|EntryPoint)")
classes = OrderedDict()
supers = {}
members = defaultdict(list)
funcs = defaultdict(OrderedDict)
with open(dump, encoding="utf-8", errors="replace") as f:
    for line in f:
        m = line_re.match(line)
        if not m:
            continue
        kind, path, rest = m.groups()
        if not path.startswith(prefix):
            continue
        if kind.endswith("GeneratedClass"):
            classes[path] = kind
            continue
        parts = path.split(":")
        if len(parts) < 2:
            continue
        cls = parts[0]
        off = re.search(r"\[o: ([0-9A-F]+)\]", rest)
        if kind == "Function" and len(parts) == 2:
            if not parts[1].startswith("ExecuteUbergraph"):
                funcs[cls].setdefault(parts[1], [])
        elif kind.endswith("Property") and len(parts) == 2:
            if not skip.match(parts[1]):
                members[cls].append(f"{kind.replace('Property', '')} {parts[1]}" + (f" @0x{off.group(1)}" if off else ""))
        elif kind.endswith("Property") and len(parts) == 3 and not skip.match(parts[2]):
            if parts[1] in funcs[cls]:
                funcs[cls][parts[1]].append(f"{kind.replace('Property', '')} {parts[2]}")
with open(out, "w", encoding="utf-8") as o:
    for cls in classes:
        o.write(f"=== {cls}\n")
        for mem in members[cls]:
            o.write(f"  var {mem}\n")
        for fn, ps in funcs[cls].items():
            o.write(f"  fn {fn}({', '.join(ps)})\n")
print("classes", len(classes))
