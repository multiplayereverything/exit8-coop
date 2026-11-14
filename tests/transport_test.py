"""Offline transport test for e8net.dll: no game needed.

Two child processes each load their own copy of the DLL (the IPC folder is <dll folder>/../ipc), then drive it through
the same numbered-file protocol the Lua mod uses. Checks: LAN host/join, handshake, payload both ways, version
mismatch refused with both versions named, peer_left on close.
Run: python -I tests/transport_test.py <path to e8net.dll>
"""
import ctypes, os, shutil, subprocess, sys, tempfile, time

PORT = 27089  # test-only port, not the mod's default


class Side:
    def __init__(self, root):
        self.ipc = os.path.join(root, "ipc")
        self.out_seq = 0
        self.in_seq = 0
        self.lines = []

    def send(self, *lines):
        self.out_seq += 1
        tmp = os.path.join(self.ipc, f"out.{self.out_seq}.tmp")
        with open(tmp, "w", newline="\n") as f:
            f.write("\n".join(lines) + "\n")
        os.replace(tmp, os.path.join(self.ipc, f"out.{self.out_seq}"))

    def poll(self):
        while True:
            p = os.path.join(self.ipc, f"in.{self.in_seq + 1}")
            if not os.path.exists(p):
                return
            with open(p) as f:
                self.lines += [l for l in f.read().split("\n") if l]
            os.remove(p)
            self.in_seq += 1

    def wait(self, pred, timeout=8.0):
        end = time.time() + timeout
        while time.time() < end:
            self.poll()
            for l in self.lines:
                if pred(l):
                    return l
            time.sleep(0.02)
        return None


def child(dll):
    ctypes.WinDLL(dll)
    while True:
        time.sleep(1)


def main():
    if len(sys.argv) > 2 and sys.argv[1] == "--child":
        child(sys.argv[2])
        return
    dll = os.path.abspath(sys.argv[1])
    tmp = tempfile.mkdtemp(prefix="e8net-test-")
    procs, fails = [], []

    def make(name):
        root = os.path.join(tmp, name)
        os.makedirs(os.path.join(root, "native"))
        shutil.copy(dll, os.path.join(root, "native", "e8net.dll"))
        procs.append(subprocess.Popen([sys.executable, "-I", __file__, "--child", os.path.join(root, "native", "e8net.dll")]))
        time.sleep(0.5)
        return Side(root)

    def check(name, ok):
        print(("PASS " if ok else "FAIL ") + name)
        if not ok:
            fails.append(name)

    try:
        h, c, bad = make("host"), make("client"), make("bad")
        h.send(f"!host lan {PORT} 1 0.1.0 Host")
        check("host listening", h.wait(lambda l: l.startswith("#hosting lan")) is not None)
        c.send(f"!join lan 127.0.0.1 {PORT} 1 0.1.0 Guest")
        check("client welcomed as id 2", c.wait(lambda l: l.startswith("#connected 2")) is not None)
        check("host sees peer_join", h.wait(lambda l: l.startswith("#peer_join 2 Guest")) is not None)
        h.send("S|1|hello from host")
        c.send("S|2|hello from client")
        check("client got host payload", c.wait(lambda l: l == "S|1|hello from host") is not None)
        check("host got client payload", h.wait(lambda l: l == "S|2|hello from client") is not None)
        bad.send(f"!join lan 127.0.0.1 {PORT} 1 0.0.9 Old")
        r = bad.wait(lambda l: l.startswith("#rejected"))
        check("version mismatch refused naming both", r is not None and "0.1.0" in r and "0.0.9" in r)
        c.send("!stop")
        check("host sees peer_left", h.wait(lambda l: l.startswith("#peer_left 2")) is not None)
    finally:
        for p in procs:
            p.kill()
        time.sleep(0.3)
        shutil.rmtree(tmp, ignore_errors=True)
    print("RESULT", "FAIL" if fails else "PASS")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
