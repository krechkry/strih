"""Downloads Firefox's translation models for some language directions the way Firefox does (Remote Settings).
Usage: python3 fetch.py out_dir csen encs sken ensk"""
import gzip, json, os, sys, urllib.request

out, pairs = sys.argv[1], sys.argv[2:]
BASE = "https://firefox.settings.services.mozilla.com/v1"
recs = json.load(urllib.request.urlopen(f"{BASE}/buckets/main/collections/translations-models/records"))["data"]
cdn = json.load(urllib.request.urlopen(f"{BASE}/"))["capabilities"]["attachments"]["base_url"]

def ver(r):
    return tuple(int(x) if x.isdigit() else 0 for x in r.get("version", "0").replace("a", ".").split("."))

langs = sorted({(r.get("fromLang"), r.get("toLang")) for r in recs})
print("directions:", " ".join(f"{a}{b}" for a, b in langs))
print("record keys:", sorted(recs[0].keys()))
for pair in pairs:
    a, b = pair[:2], pair[2:]
    mine = [r for r in recs if r.get("fromLang") == a and r.get("toLang") == b]
    if not mine:
        print(pair, "MISSING"); continue
    # newest version that Firefox release would use (no filter = everyone)
    best = max(ver(r) for r in mine)
    newest = [r for r in mine if ver(r) == best]
    d = os.path.join(out, pair); os.makedirs(d, exist_ok=True)
    total = 0
    for r in newest:
        att = r["attachment"]
        data = urllib.request.urlopen(cdn + att["location"]).read()
        if att["filename"].endswith(".gz") or data[:2] == b"\x1f\x8b":
            data = gzip.decompress(data)
        name = att["filename"].removesuffix(".gz")
        open(os.path.join(d, name), "wb").write(data)
        total += att["size"]
        print(f"  {pair} v{r.get('version')} {r.get('fileType')} {name} {att['size']} filter={r.get('filter_expression')!r} arch={r.get('architecture')}")
    print(f"{pair}: {total / 1e6:.1f} MB download")
