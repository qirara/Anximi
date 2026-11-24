#!/usr/bin/env python3
"""模拟 pm/am/appops/settings/cmd/dumpsys/iptables/getprop，状态存在 $MOCK/state.json。
仅用于在 PC 上做 anximi.sh 的端到端测试。"""
import json, os, sys

M = os.environ["MOCK"]
SF = os.path.join(M, "state.json")
name = os.path.basename(sys.argv[0])
argv = sys.argv[1:]
with open(os.path.join(M, "calls.log"), "a") as f:
    f.write(name + " " + " ".join(argv) + "\n")

def load():
    with open(SF) as f:
        return json.load(f)

def save(s):
    with open(SF, "w") as f:
        json.dump(s, f, indent=1)

def pop_user(a):
    u = "0"
    if "--user" in a:
        i = a.index("--user"); u = a[i + 1]; del a[i:i + 2]
    return u

s = load()
out = print

if name == "getprop":
    out(s["props"].get(argv[0], "") if argv else "")
elif name == "pm":
    sub, a = argv[0], argv[1:]
    u = pop_user(a)
    pk = s["pkgs"]
    def st(p):  # 每用户状态
        return s.setdefault("u", {}).setdefault(u, {}).setdefault(p, {"inst": True, "dis": False, "perms": list(pk[p].get("perms", []))})
    if sub == "list" and a[0] == "users":
        out("Users:")
        for uid, nm in s["users"]:
            out(f"\tUserInfo{{{uid}:{nm}:c13}} running")
    elif sub == "list":
        flags = set(a[1:])
        for p, info in pk.items():
            x = st(p)
            if "-u" not in flags and not x["inst"]:
                continue
            if "-d" in flags and not x["dis"]:
                continue
            line = f"package:{p}"
            if "-U" in flags:
                line += f" uid:{int(u) * 100000 + info['appid']}"
            out(line)
    elif sub in ("disable-user", "enable", "uninstall", "install-existing", "disable", "default-state"):
        p = [x for x in a if not x.startswith("-")][0]
        if "/" in p:
            s.setdefault("comps", {}).setdefault(u, {})[p] = (sub == "disable")
        else:
            if p not in pk:
                sys.exit(1)
            x = st(p)
            if sub == "disable-user": x["dis"] = True
            elif sub == "enable": x["dis"] = False
            elif sub == "uninstall": x["inst"] = False
            elif sub == "install-existing": x["inst"] = True
        save(s); out("Success")
    elif sub in ("grant", "revoke"):
        p, perm = a[0], a[1]
        x = st(p)
        if sub == "revoke" and perm in x["perms"]: x["perms"].remove(perm)
        if sub == "grant" and perm not in x["perms"]: x["perms"].append(perm)
        save(s)
    elif sub == "path":
        out("package:/system/framework/framework-res.apk")
elif name == "dumpsys":
    if argv[0] == "package":
        p = argv[1]
        out("Packages:")
        out(f"  Package [{p}] (abc):")
        out("    install permissions:")
        out("      android.permission.INTERNET: granted=true")
        for uid, _ in s["users"]:
            x = s.get("u", {}).get(str(uid), {}).get(p, {"perms": s["pkgs"].get(p, {}).get("perms", [])})
            out(f"    User {uid}: ceDataInode=1 installed=true")
            out("      runtime permissions:")
            for perm in x["perms"]:
                out(f"        {perm}: granted=true, flags=[ USER_SET ]")
        out(f"  Service Resolver Table:\n      {p}/.UploadService\n      {p}/com.x.Tracker")
elif name == "appops":
    sub, a = argv[0], argv[1:]
    u = pop_user(a)
    ops = s.setdefault("appops", {})
    key = f"{u}:{a[0]}:{a[1]}"
    if sub == "get":
        if key in ops: out(f"{a[1]}: {ops[key]}; time=+1d")
        else: out("No operations.")
    elif sub == "set":
        if a[2] == "default": ops.pop(key, None)
        else: ops[key] = a[2]
        save(s)
elif name == "settings":
    sub, ns, k = argv[0], argv[1], argv[2]
    d = s.setdefault("settings", {})
    key = f"{ns}:{k}"
    if sub == "get": out(d.get(key, "null"))
    elif sub == "put": d[key] = argv[3]; save(s)
    elif sub == "delete": d.pop(key, None); save(s)
elif name == "am":
    sub, a = argv[0], argv[1:]
    u = pop_user(a)
    b = s.setdefault("bucket", {})
    if sub == "get-standby-bucket": out(b.get(f"{u}:{a[0]}", 10))
    elif sub == "set-standby-bucket":
        names = {"active": 10, "working_set": 20, "frequent": 30, "rare": 40, "restricted": 45}
        b[f"{u}:{a[0]}"] = names.get(a[1], a[1]); save(s)
elif name == "cmd":
    if argv[:2] == ["connectivity", "help"]:
        out("  set-chain3-enabled\n  set-package-networking-enabled")
    elif argv and argv[0] == "connectivity":
        s.setdefault("bpf", []).append(" ".join(argv[1:])); save(s)
elif name in ("iptables", "ip6tables"):
    a = [x for x in argv if x != "-w"]
    t = s.setdefault(name, {"OUTPUT": ["oem_out", "fw_OUTPUT"], "chains": {}})
    op = a[0]
    if op == "-N":
        if a[1] in t["chains"]: sys.exit(1)
        t["chains"][a[1]] = []
    elif op == "-F":
        if a[1] not in t["chains"]: sys.exit(1)
        t["chains"][a[1]] = []
    elif op == "-X":
        if a[1] not in t["chains"]: sys.exit(1)
        del t["chains"][a[1]]
    elif op == "-A":
        t["chains"][a[1]].append(" ".join(a[2:]))
    elif op == "-I":
        t["OUTPUT"].insert(int(a[2]) - 1, a[4])
    elif op == "-C":
        sys.exit(0 if a[3] in t["OUTPUT"] else 1)
    elif op == "-D":
        if a[3] in t["OUTPUT"]: t["OUTPUT"].remove(a[3])
        else: sys.exit(1)
    save(s)
