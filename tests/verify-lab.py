"""Judges a two-copy lab run from the E8T-* evidence lines in host.log and client.log.

Checks (tour "loop"):
  connected      both copies report the connection (client got an id, host saw the client join)
  puppets        each copy has a puppet for the other, standing where the other copy says it is (<= 150 cm)
  choices        the host made every planned choice and the client applied the same number (same final seq)
  loopstate      at every second where both copies sit on the same seq, floor/change/tag agree after a 3 s grace
  noerrors       no E8T-MODERROR lines
With --mutant X the run is expected to FAIL the check that mutant switches off; the script exits 0 only if it does.
"""
import argparse, os, re, sys

MUTANT_BREAKS = {"noanomalysync": "loopstate", "nofloorsync": "loopstate", "noguard": "choices", "norestartsync": "loopstate",
                 "noanim": "animation", "nosmooth": "smooth", "vote1": "voting"}
STATE = re.compile(r"E8T-STATE wall=(\d+) t=\d+ role=(\w+) id=(\d+) seq=(\d+) run=(\d+) floor=(\S+) change=(\S+) tag=(\S+) me=(\S+) peer=(\S+) puppet=(\S+) applying=(\S+)(?: anim=(\S+))?")


def parse(path):
    rows, checks, errors = {}, [], []
    if not os.path.exists(path):
        return rows, checks, errors
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = STATE.search(line)
            if m:
                t = int(m.group(1))
                rows[t] = dict(t=t, role=m.group(2), id=int(m.group(3)), seq=int(m.group(4)), run=int(m.group(5)), floor=m.group(6),
                               change=m.group(7), tag=m.group(8), me=m.group(9), peer=m.group(10), puppet=m.group(11), applying=m.group(12),
                               anim=m.group(13) or "-")
            elif "E8T-CHECK" in line:
                checks.append(line.split("E8T-CHECK", 1)[1].strip())
            elif "E8T-MODERROR" in line:
                errors.append(line.strip())
    return rows, checks, errors


def xyz(s):
    try:
        return [float(v) for v in s.split(",")]
    except ValueError:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    ap.add_argument("--tour", default="loop")
    ap.add_argument("--mutant", default="")
    a = ap.parse_args()
    host, hchecks, herr = parse(os.path.join(a.run, "host.log"))
    client, cchecks, cerr = parse(os.path.join(a.run, "client.log"))
    res = {}

    res["connected"] = (any(c.startswith("connected id=2") for c in cchecks) and any(c.startswith("peer_join id=2") for c in hchecks),
                        f"client checks {cchecks[:3]}, host checks {hchecks[:3]}")

    def puppet_ok(rows, label):
        good = total = 0
        worst = 0
        for r in rows.values():
            p, q = xyz(r["puppet"]), xyz(r["peer"])
            if not p or not q or r["applying"] != "-":
                continue
            total += 1
            d = ((p[0] - q[0]) ** 2 + (p[1] - q[1]) ** 2) ** 0.5
            worst = max(worst, d)
            good += d <= 150
        return total >= 10 and good >= 0.9 * total, f"{label}: {good}/{total} samples within 150 cm (worst {worst:.0f})"

    hp, hmsg = puppet_ok(host, "host sees client")
    cp, cmsg = puppet_ok(client, "client sees host")
    # The puppet must also stand where the other copy really is: compare a copy's own position with the other's peer view.
    cross = []
    for t, r in client.items():
        h = host.get(t)
        if h and r["seq"] == h["seq"] and r["applying"] == "-":
            me, seen = xyz(r["me"]), xyz(h["peer"])
            if me and seen:
                cross.append(((me[0] - seen[0]) ** 2 + (me[1] - seen[1]) ** 2) ** 0.5)
    cross_ok = len(cross) >= 10 and sorted(cross)[int(len(cross) * 0.9) - 1] <= 300
    res["puppets"] = (hp and cp and cross_ok, f"{hmsg}; {cmsg}; client pose seen by host p90 {sorted(cross)[int(len(cross)*0.9)-1] if cross else -1:.0f} cm over {len(cross)} s")

    hseq = max((r["seq"] for r in host.values()), default=0)
    cseq = max((r["seq"] for r in client.values()), default=0)
    done = any(c.startswith("tour-done") for c in hchecks)
    own = [c for c in cchecks if c.startswith("client-own-choice")]
    res["choices"] = (done and hseq >= 3 and cseq == hseq and not own,
                      f"host made {hseq} choices, client applied {cseq}, tour-done={done}, client's own choices {len(own)} {own[:2]}")

    agree = disagree = 0
    first_bad = None
    times = sorted(t for t in host if t in client)
    since = {}
    for t in times:
        h, c = host[t], client[t]
        if h["seq"] != c["seq"] or c["applying"] != "-" or h["run"] != c["run"]:
            since.clear()
            continue
        key = (h["seq"], h["change"], h["tag"], h["floor"])   # grace restarts whenever the host's state moves
        since.setdefault(key, t)
        if t - since[key] < 3:
            continue
        same = h["floor"] == c["floor"] and h["change"] == c["change"] and (h["change"] == "false" or h["tag"] == c["tag"])
        if same:
            agree += 1
        else:
            disagree += 1
            first_bad = first_bad or (t, h["floor"], h["change"], h["tag"], c["floor"], c["change"], c["tag"])
    hrun = max((r["run"] for r in host.values()), default=0)
    crun = max((r["run"] for r in client.values()), default=0)
    res["loopstate"] = (agree >= 20 and disagree <= 2 and hrun == crun,
                        f"{agree} agreeing seconds, {disagree} disagreeing; first bad {first_bad}; restarts host {hrun} client {crun}")
    # animation: the puppet walks while its player moves and idles while they stand, and the walk really moves bones
    # (clip position advances, foot height varies). Per copy, judged from consecutive seconds of the peer's pose.
    def anim_ok(rows, label):
        times = sorted(rows)
        mv_walk = mv = st_idle = st = 0
        walk_pos, walk_foot = set(), []
        for a, b in zip(times, times[1:]):
            r0, r1 = rows[a], rows[b]
            if b - a != 1 or r1["anim"] == "-" or r1["applying"] != "-":
                continue
            p0, p1 = xyz(r0["peer"]), xyz(r1["peer"])
            if not p0 or not p1:
                continue
            d = ((p1[0] - p0[0]) ** 2 + (p1[1] - p0[1]) ** 2) ** 0.5
            parts = r1["anim"].split("/")
            clip = parts[0]
            if 60 < d < 600:
                mv += 1
                mv_walk += clip == "walk"
                if clip == "walk" and len(parts) >= 3:
                    walk_pos.add(parts[1])
                    walk_foot.append(float(parts[2]))
            elif d < 5:
                st += 1
                st_idle += clip == "idle"
        foot_range = (max(walk_foot) - min(walk_foot)) if walk_foot else 0
        ok = mv >= 5 and mv_walk >= 0.7 * mv and st >= 5 and st_idle >= 0.7 * st and len(walk_pos) >= 3 and foot_range > 5
        return ok, (f"{label}: walking {mv_walk}/{mv} s while the peer moved, idle {st_idle}/{st} s while still, "
                    f"{len(walk_pos)} distinct walk clip positions, foot height range {foot_range:.1f} cm")
    # smoothness: per second, the mod reports frames walking : coefficient of variation of the per-frame drawn speed
    # : share of frames that moved. Stop-go puppets (moved 10 times a second) give a CV well above 1.
    def smooth_ok(rows, label):
        cvs, moved = [], []
        for r in rows.values():
            parts = r["anim"].split("/")
            if len(parts) >= 5 and parts[4] != "-" and r["applying"] == "-":
                n, cv, mv = parts[4].split(":")
                if int(n) >= 10:
                    cvs.append(float(cv)); moved.append(float(mv))
        if len(cvs) < 10:
            return False, f"{label}: only {len(cvs)} walking seconds measured"
        cvs.sort(); moved.sort()
        med_cv, med_mv = cvs[len(cvs) // 2], moved[len(moved) // 2]
        return med_cv < 0.5 and med_mv > 0.85, f"{label}: {len(cvs)} walking seconds, median speed CV {med_cv:.2f}, moved on {med_mv:.0%} of frames"
    # voting (vote mode): every commit had all players at the same line; the client's deliberate split vote happened
    # (and so was held without a commit); one commit per choice.
    commits = [c for c in hchecks if c.startswith("commit")]
    if commits:
        bad = []
        for c in commits:
            m = re.search(r"dir=(\w+) seq=\d+ votes=(\S+)", c)
            votes = [v.split(":")[1] for v in m.group(2).split(",")] if m else []
            if not m or not votes or any(v != m.group(1) for v in votes):
                bad.append(c)
        split = any(c.startswith("split-start") for c in cchecks) and any(c.startswith("split-end") for c in cchecks)
        res["voting"] = (not bad and split and len(commits) == hseq,
                         f"{len(commits)} commits for {hseq} choices, {len(bad)} without full agreement {bad[:1]}, split vote held={split}")
    # look: each copy's puppet is the tinted mannequin, coloured for the other player's id
    def look_ok(checks, peer_id, label):
        looks = [c for c in checks if c.startswith(f"puppet-look id={peer_id} ")]
        good = [c for c in looks if "mesh=SKM_Manny" in c and "tint=none" not in c]
        return bool(looks) and len(good) == len(looks), f"{label}: {looks[-1] if looks else 'no puppet-look line'}"
    hl, hmsg4 = look_ok(hchecks, 2, "host's puppet of client")
    cl, cmsg4 = look_ok(cchecks, 1, "client's puppet of host")
    res["look"] = (hl and cl, f"{hmsg4}; {cmsg4}")
    # steam (only for -Steam runs): real lobby created and joined, and the in-process message self-test passed on both
    if any(c.startswith(("steam-", "steamselftest")) for c in hchecks + cchecks):
        created = [c for c in hchecks if c.startswith("steam-lobby-created")]
        joined = [c for c in cchecks if c.startswith("steam-lobby-joined")]
        hst = [c for c in hchecks if c.startswith("steamselftest")]
        cst = [c for c in cchecks if c.startswith("steamselftest")]
        ok = bool(created) and bool(joined) and hst and cst and all(" ok " in c + " " for c in hst + cst)
        res["steam"] = (bool(ok), f"lobby created {created[:1]}, joined {joined[:1]}, self-test host {hst[:1]} client {cst[:1]}")
    hs, hmsg3 = smooth_ok(host, "host's puppet of client")
    cs, cmsg3 = smooth_ok(client, "client's puppet of host")
    res["smooth"] = (hs and cs, f"{hmsg3}; {cmsg3}")
    ha, hmsg2 = anim_ok(host, "host's puppet of client")
    ca, cmsg2 = anim_ok(client, "client's puppet of host")
    res["animation"] = (ha and ca, f"{hmsg2}; {cmsg2}")
    res["noerrors"] = (not herr and not cerr, f"{len(herr)} host / {len(cerr)} client mod errors {(herr + cerr)[:2]}")

    ok = all(v[0] for v in res.values())
    for k, (passed, msg) in res.items():
        print(f"{'PASS' if passed else 'FAIL'} {k}: {msg}")
    if a.mutant:
        target = MUTANT_BREAKS.get(a.mutant)
        killed = target is not None and not res[target][0]
        print(f"MUTANT {a.mutant}: {'killed' if killed else 'SURVIVED'} (expects {target} to fail)")
        sys.exit(0 if killed else 1)
    print("RESULT", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
