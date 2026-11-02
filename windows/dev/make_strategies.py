# Builds app/strategies.txt  (format: ENGINE|NAME|ARGS)
import re, glob, os, sys
R = sys.argv[1]  # path to Flowseal repo
out = []

# ---- 1. GoodbyeDPI (same set as v1) ----
MODE_GROUP = {1: "g_nofake", 2: "g_nofake", 3: "g_nofake", 4: "g_nofake", 5: "g_autottl",
              6: "g_badseq", 7: "g_badsum", 8: "g_badsumseq", 9: "g_badsumseq"}
for m in range(1, 10):
    out.append(("gdpi", f"GoodbyeDPI mode -{m}", f"-{m}" + ("" if m == 9 else " -q"), MODE_GROUP[m]))
fakes = [("", "no fake", "g_nofake"), ("--wrong-chksum", "fake badsum", "g_badsum"), ("--wrong-seq", "fake badseq", "g_badseq"),
         ("--wrong-chksum --wrong-seq", "fake badsum+badseq", "g_badsumseq"), ("--auto-ttl", "fake autottl", "g_autottl"),
         ("--set-ttl 3", "fake ttl3", "g_ttl"), ("--set-ttl 5", "fake ttl5", "g_ttl")]
frags = [("-e 1 --native-frag", "split1"), ("-e 2 --reverse-frag", "rev2"),
         ("-e 2 --native-frag --frag-by-sni", "split@SNI"), ("-e 2 --reverse-frag --frag-by-sni", "rev@SNI"),
         ("-e 40 --reverse-frag", "rev40")]
for fa, fn, fg in fakes:
    for ra, rn in frags:
        args = re.sub(r"\s+", " ", f"-p -r -s -f 2 {ra} {fa} --max-payload -q").strip()
        out.append(("gdpi", f"GoodbyeDPI {rn} {fn}", args, fg))

def zgroup(args):
    main = args.split(" --new ")[-1]
    m = re.search(r"--dpi-desync=(\S+)", main)
    mode = m.group(1) if m else ""
    if any(k in mode for k in ("fake", "hostfakesplit")):
        f = re.search(r"--dpi-desync-fooling=([a-z0-9]+)", main)
        if f: fool = f.group(1)
        elif "--dpi-desync-autottl" in main: fool = "autottl"
        elif "--dpi-desync-ttl" in main: fool = "ttl"
        else: fool = "none"
        return "z_fake_" + fool
    return "z_seqovl" if "seqovl" in main else "z_split"

# ---- 2. Flowseal zapret presets ----
def profiles(path):
    t = open(path, encoding="utf-8", errors="ignore").read()
    t = re.sub(r"\^\s*\r?\n", " ", t)
    m = re.search(r'winws\.exe"\s+(.*)', t)
    pr = [p.strip() for p in m.group(1).split(" --new ")]
    pr[0] = re.sub(r"^(--wf-\S+\s+)+", "", pr[0])
    return pr

def clean(p, keep_google=False):
    toks = re.findall(r'--[\w-]+(?:="[^"]*"|=\S+)?', p)
    res = []
    for k in toks:
        if k.startswith(("--hostlist", "--ipset")):
            if keep_google and "list-google" in k:
                res.append('--hostlist="{LISTS}list-google.txt"')
            continue
        res.append(k)
    # "^!" = winws built-in fake; "!" cannot pass through batch delayed expansion, use an equivalent file
    s = " ".join(res).replace("=^!", '="%BIN%tls_clienthello_www_google_com.bin"').replace("%BIN%", "{BIN}").replace("%LISTS%", "{LISTS}")
    assert "%" not in s and "!" not in s, s
    return s

QUIC = None
files = sorted(glob.glob(os.path.join(R, "general*.bat")), key=lambda f: (f != os.path.join(R, "general.bat"), f))
for f in files:
    pr = profiles(f)
    quic = next((p for p in pr if p.startswith("--filter-udp=443 ")), None)
    goog = next((p for p in pr if p.startswith("--filter-tcp=443 ") and "list-google" in p), None)
    tcpm = [p for p in pr if re.search(r"--filter-tcp=80,443", p)]
    main = next((p for p in tcpm if "list-general" in p), tcpm[0])
    parts = [clean(quic) if quic else QUIC] + ([clean(goog, True)] if goog else []) + [clean(main)]
    parts[-1] = re.sub(r"--filter-tcp=\S+", "--filter-tcp=80,443", parts[-1])
    name = os.path.basename(f)[:-4].replace("general", "Flowseal").replace("(", "").replace(")", "").strip()
    if name == "Flowseal": name = "Flowseal general"
    a = "--wf-tcp=80,443 --wf-udp=443 " + " --new ".join(parts)
    out.append(("zapret", name, a, zgroup(a)))
    if QUIC is None: QUIC = clean(quic)

# ---- 3. blockcheck-style generated zapret strategies ----
G = '{BIN}tls_clienthello_www_google_com.bin'
tcp = []
for mode in ["multisplit", "multidisorder"]:
    for pos in ["1", "2", "midsld", "sniext+1", "host+1", "1,midsld", "1,sniext+1,host+1,midsld-2,midsld,midsld+2,endhost-1"]:
        tcp.append((f"{mode} pos={pos}", f"--dpi-desync={mode} --dpi-desync-split-pos={pos}"))
for ovl, pat in [("681", "google"), ("568", "4pda"), ("336", "google")]:
    pf = G if pat == "google" else "{BIN}tls_clienthello_4pda_to.bin"
    tcp.append((f"multisplit seqovl={ovl} {pat}", f'--dpi-desync=multisplit --dpi-desync-split-seqovl={ovl} --dpi-desync-split-pos=1 --dpi-desync-split-seqovl-pattern="{pf}"'))
tcp.append(("multidisorder seqovl midsld", "--dpi-desync=multidisorder --dpi-desync-split-pos=midsld --dpi-desync-split-seqovl=midsld-1"))
fool = [("badseq", "--dpi-desync-fooling=badseq"), ("md5sig", "--dpi-desync-fooling=md5sig"),
        ("badsum", "--dpi-desync-fooling=badsum"), ("ts", "--dpi-desync-fooling=ts"),
        ("ttl4", "--dpi-desync-ttl=4"), ("autottl", "--dpi-desync-autottl=2")]
for fn, fa in fool:
    tcp.append((f"fake {fn}", f'--dpi-desync=fake --dpi-desync-repeats=6 {fa} --dpi-desync-fake-tls="{G}"'))
    for mode in ["multisplit", "multidisorder"]:
        for pos in ["1", "midsld"]:
            tcp.append((f"fake+{mode} pos={pos} {fn}", f'--dpi-desync=fake,{mode} --dpi-desync-split-pos={pos} --dpi-desync-repeats=6 {fa} --dpi-desync-fake-tls="{G}"'))
    for mode in ["fakedsplit", "fakeddisorder"]:
        tcp.append((f"{mode} midsld {fn}", f"--dpi-desync={mode} --dpi-desync-split-pos=midsld --dpi-desync-repeats=6 {fa}"))
    tcp.append((f"hostfakesplit {fn}", f"--dpi-desync=hostfakesplit --dpi-desync-hostfakesplit-mod=host=www.google.com --dpi-desync-repeats=4 {fa}"))
    tcp.append((f"fake rndsni {fn}", f"--dpi-desync=fake --dpi-desync-repeats=6 {fa} --dpi-desync-fake-tls-mod=rnd,rndsni,dupsid"))
# decoys that look more like the real handshake (best fooling methods from real tests)
for fn, fa in [("badseq", "--dpi-desync-fooling=badseq"), ("ts", "--dpi-desync-fooling=ts"), ("autottl", "--dpi-desync-autottl=2")]:
    tcp.append((f"fake+multisplit padencap {fn}", f'--dpi-desync=fake,multisplit --dpi-desync-split-pos=1 --dpi-desync-repeats=6 {fa} --dpi-desync-fake-tls="{G}" --dpi-desync-fake-tls-mod=padencap'))
    tcp.append((f"fake+multidisorder dupsid {fn}", f'--dpi-desync=fake,multidisorder --dpi-desync-split-pos=midsld --dpi-desync-repeats=6 {fa} --dpi-desync-fake-tls="{G}" --dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com'))
for n, a in tcp:
    za = f"--wf-tcp=80,443 --wf-udp=443 {QUIC} --new --filter-tcp=80,443 {a}"
    out.append(("zapret", f"zapret {n}", za, zgroup(za)))

with open(sys.argv[2], "w", newline="\r\n") as fh:
    fh.write("# AutoDPI strategy list. One per line:  ENGINE|TYPE|NAME|ARGUMENTS\n")
    fh.write("# TYPE groups similar settings: the first setting of each type is tested first,\n")
    fh.write("# and the other settings of a type are only tried when that type works.\n")
    fh.write("# ENGINE is gdpi or zapret. {BIN} = app\\engines\\zapret\\  {LISTS} = app\\engines\\zapret\\lists\\\n")
    fh.write("# You can add, remove or reorder lines. Do not use the characters ! % & ^ in arguments.\n")
    for e, n, a, g in out:
        assert "|" not in n + a and "!" not in a and "&" not in a and re.fullmatch(r"[a-z0-9_]+", g)
        fh.write(f"{e}|{g}|{n}|{a}\n")
import collections
print(collections.Counter(g for *_, g in out))
print(len(out), "strategies;", sum(1 for o in out if o[0]=="gdpi"), "gdpi,", sum(1 for o in out if o[0]=="zapret"), "zapret")
