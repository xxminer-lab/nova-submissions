#!/bin/bash
# FAST NOVA Boltz-2 pre-screen bootstrap for Modal, with PRE-DOWNLOADED weights.
# Usage: run_rxn_prescreen_v7.sh <RXN_ID> <LIMIT>
#
# KEY FIX vs v6: try HuggingFace FIRST (works at ~56 MB/s with redirect-follow),
# model-gateway only as fallback. v6 tried model-gateway first, which hangs
# indefinitely (0 bytes) and urlretrieve has no timeout -> never fell back to HF.
# We add socket.setdefaulttimeout so a stalled connection raises and falls back.
set -e
RXN_ID="${1:-2}"
LIMIT="${2:-400}"
echo "BOOTSTRAP_V7 rxn=${RXN_ID} limit=${LIMIT}"

mkdir -p /nova
cd /tmp
python3 - <<'PY'
import urllib.request, tarfile, io
d = urllib.request.urlopen("https://codeload.github.com/metanova-labs/nova/tar.gz/refs/heads/main").read()
tarfile.open(fileobj=io.BytesIO(d), mode="r:gz").extractall(".")
print("repo extracted")
PY
cp -r nova-main/. /nova/ 2>/dev/null || cp -r nova-main/* /nova/

# Extract boltz deps from pyproject.toml and install them (no boltz build).
cd /nova/external_tools/boltz
python3 - <<'PY' > /tmp/boltz_deps.txt
import re
deps = []
in_dep = False
for line in open("pyproject.toml"):
    if line.strip().startswith("dependencies"):
        in_dep = True
        continue
    if in_dep:
        if line.strip().startswith("]"):
            break
        m = re.search(r'"([^"]+)"', line)
        if m:
            deps.append(m.group(1))
deps = [d for d in deps if not d.startswith("wandb")]
print(" ".join('"%s"' % d for d in deps))
PY
DEPS=$(cat /tmp/boltz_deps.txt)
echo "installing deps: $DEPS"
eval pip install $DEPS pytorch-lightning omegaconf 2>&1 | tail -8
echo "PIP_EXIT=${PIPESTATUS[0]}"
python3 -c "import pytorch_lightning, omegaconf, rdkit, einops, fairscale; print('imports OK pl=', pytorch_lightning.__version__)"

# PRE-DOWNLOAD Boltz-2 weights. HF FIRST (fast), model-gateway as fallback.
# socket.setdefaulttimeout ensures a stalled connection raises and falls back.
export BOLTZ_CACHE=/nova/boltz_cache
mkdir -p "$BOLTZ_CACHE"
echo "pre-downloading Boltz-2 weights to $BOLTZ_CACHE (HF first)"
python3 - <<'PY'
import urllib.request, os, tarfile, socket, time
socket.setdefaulttimeout(180)  # a stalled read raises TimeoutError -> fallback
cache = os.environ["BOLTZ_CACHE"]
def dl(url, dest):
    if os.path.exists(dest) and os.path.getsize(dest) > 1000000:
        print(f"exists: {dest} ({os.path.getsize(dest)} bytes)", flush=True)
        return True
    print(f"downloading {url}", flush=True)
    t0 = time.time()
    urllib.request.urlretrieve(url, dest)
    sz = os.path.getsize(dest)
    print(f"done: {dest} ({sz} bytes in {time.time()-t0:.0f}s = {sz/1e6/max(time.time()-t0,1):.1f} MB/s)", flush=True)
    return sz > 1000000
for name, urls in [
    ("boltz2_conf.ckpt", ["https://huggingface.co/boltz-community/boltz-2/resolve/main/boltz2_conf.ckpt",
                          "https://model-gateway.boltz.bio/boltz2_conf.ckpt"]),
    ("boltz2_aff.ckpt", ["https://huggingface.co/boltz-community/boltz-2/resolve/main/boltz2_aff.ckpt",
                         "https://model-gateway.boltz.bio/boltz2_aff.ckpt"]),
    ("mols.tar", ["https://huggingface.co/boltz-community/boltz-2/resolve/main/mols.tar"]),
]:
    dest = os.path.join(cache, name)
    ok = False
    for url in urls:
        try:
            if dl(url, dest):
                ok = True
                break
        except Exception as e:
            print(f"failed {url}: {type(e).__name__}: {e}", flush=True)
    if not ok:
        raise RuntimeError(f"could not download {name}")
mols_dir = os.path.join(cache, "mols")
if not os.path.isdir(mols_dir):
    print("extracting mols.tar", flush=True)
    with tarfile.open(os.path.join(cache, "mols.tar")) as tar:
        tar.extractall(cache)
print("weights ready:", sorted(os.listdir(cache)), flush=True)
PY
echo "WEIGHTS_READY"

cd /nova
python3 - <<PY
import urllib.request
base = "https://raw.githubusercontent.com/xxminer-lab/nova-submissions/main/mining/"
urllib.request.urlretrieve(base + "score_candidates_incr.py", "/nova/score_candidates_incr.py")
urllib.request.urlretrieve(base + "candidates_rxn${RXN_ID}.tsv", "/nova/candidates.tsv")
print("fetched scorer + candidates")
PY

echo "FETCHED"; wc -l /nova/candidates.tsv
# Stream SCORE lines live (line-buffered) so ModalLogs can harvest partial results.
python3 /nova/score_candidates_incr.py --candidates /nova/candidates.tsv --out "/nova/scores_rxn${RXN_ID}.tsv" --target P40261 --limit "${LIMIT}" 2>&1 \
  | grep --line-buffered -E "SCORE|Scoring|Wrote|Scored|Error|Traceback|error"
echo "DONE"
python3 - <<PY
import csv, os
p = "/nova/scores_rxn${RXN_ID}.tsv"
if os.path.exists(p):
    rows = list(csv.DictReader(open(p), delimiter="\t"))
    rows = [r for r in rows if r.get("score") not in (None, "", "None")]
    rows.sort(key=lambda r: float(r["score"]), reverse=True)
    print("=== TOP 25 rxn${RXN_ID} ===")
    for r in rows[:25]:
        print(r["name"], r["score"])
else:
    print("no scores file produced")
PY

# Dump the FULL scores TSV as a base64 blob so a single short ModalLogs tail
# captures every score (SCORE lines scroll out of the tail window otherwise).
python3 - <<PY
import base64, os
p = "/nova/scores_rxn${RXN_ID}.tsv"
if os.path.exists(p):
    b = base64.b64encode(open(p, "rb").read()).decode()
    print("SCORES_B64_BEGIN")
    for i in range(0, len(b), 1000):
        print(b[i:i+1000])
    print("SCORES_B64_END")
else:
    print("no scores file for b64 dump")
PY
