"""Packages artifacts/mod/Exit8Together (from scripts/build.ps1) as the mod-only release ZIP:
artifacts/release/Exit8Together-UE4SS-<version>.zip + .sha256, entries with '/' relative to Exit8/Binaries/Win64.
Usage: python -I scripts/package.py <version>"""
import hashlib, os, sys, zipfile

ver = sys.argv[1]
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = os.path.join(root, "artifacts", "mod", "Exit8Together")
os.makedirs(os.path.join(root, "artifacts", "release"), exist_ok=True)
out = os.path.join(root, "artifacts", "release", f"Exit8Together-UE4SS-{ver}.zip")
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:   # "w" replaces an older ZIP of the same version
    for d, _, files in os.walk(src):
        for f in sorted(files):
            if f.endswith((".log", ".tmp")) or os.sep + "ipc" in d:
                continue
            p = os.path.join(d, f)
            z.write(p, "ue4ss/Mods/Exit8Together/" + os.path.relpath(p, src).replace(os.sep, "/"))
    for f in ("README.md", "LICENSE"):
        z.write(os.path.join(root, f), "ue4ss/Mods/Exit8Together/" + f)
h = hashlib.sha256(open(out, "rb").read()).hexdigest()
open(out + ".sha256", "w", newline="\n").write(f"{h}  {os.path.basename(out)}\n")
print(out)
print(h)
for n in zipfile.ZipFile(out).namelist():
    print("  " + n)
