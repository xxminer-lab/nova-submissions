#!/bin/bash
# FAST NOVA Boltz-2 pre-screen bootstrap for Modal, with PRE-DOWNLOADED weights.
# Usage: run_rxn_prescreen_v11.sh <RXN_ID> <LIMIT> <OFFSET> <CAND_FILE>
#
# v10 FIX: the single long-lived urlretrieve connection to HF xet stalls at 0 bytes
# (15+ consecutive stalls). A 2MB Range probe succeeds in 0.4s, so the CDN is fine
# for SHORT transfers. v10 downloads in 64MB chunks, each on a FRESH connection with
# a hard per-chunk timeout + resume, so a stalled chunk is retried, not the whole file.
set -e
RXN_ID="${1:-2}"
LIMIT="${2:-120}"
OFFSET="${3:-0}"
CAND_FILE="${4:-candidates_rxn${RXN_ID}.tsv}"
echo "BOOTSTRAP_V10 rxn=${RXN_ID} limit=${LIMIT} offset=${OFFSET}"

mkdir -p /nova
cd /tmp
python3 - <<'PY'
import urllib.request, tarfile, io
d = urllib.request.urlopen("https://codeload.github.com/metanova-labs/nova/tar.gz/refs/heads/main").read()
tarfile.open(fileobj=io.BytesIO(d), mode="r:gz").extractall(".")
print("repo extracted")
PY
cp -r nova-main/. /nova/ 2>/dev/null || cp -r nova-main/* /nova/

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

export BOLTZ_CACHE=/nova/boltz_cache
mkdir -p "$BOLTZ_CACHE"
echo "pre-downloading Boltz-2 weights to $BOLTZ_CACHE (chunked/resumable)"
python3 - <<'PY'
import urllib.request, os, tarfile, time
CHUNK = 64 * 1024 * 1024  # 64MB per fresh connection
cache = os.environ["BOLTZ_CACHE"]

def get_size(url):
    req = urllib.request.Request(url, method="HEAD")
    with urllib.request.urlopen(req, timeout=30) as r:
        return int(r.headers["Content-Length"])

def dl_chunked(url, dest):
    if os.path.exists(dest) and os.path.getsize(dest) > 1000000:
        print(f"exists: {dest} ({os.path.getsize(dest)} bytes)", flush=True)
        return True
    total = get_size(url)
    print(f"downloading {url} ({total/1e6:.0f} MB, chunked)", flush=True)
    t0 = time.time()
    with open(dest + ".part", "wb") as f:
        pos = 0
        while pos < total:
            end = min(pos + CHUNK - 1, total - 1)
            for attempt in range(12):
                try:
                    req = urllib.request.Request(url, headers={"Range": f"bytes={pos}-{end}"})
                    with urllib.request.urlopen(req, timeout=60) as r:
                        f.write(r.read())
                    break
                except Exception as e:
                    wait = min(5 * (2 ** attempt), 120)
                    print(f"chunk {pos}-{end} attempt {attempt+1} failed: {type(e).__name__}; backoff {wait}s", flush=True)
                    time.sleep(wait)
                    if attempt == 11:
                        raise
            pos = end + 1
            print(f"  {pos/1e6:.0f}/{total/1e6:.0f} MB ({pos/1e6/max(time.time()-t0,1):.1f} MB/s)", flush=True)
    os.rename(dest + ".part", dest)
    sz = os.path.getsize(dest)
    print(f"done: {dest} ({sz} bytes in {time.time()-t0:.0f}s)", flush=True)
    return sz > 1000000

for name, url in [
    ("boltz2_conf.ckpt", "https://huggingface.co/boltz-community/boltz-2/resolve/main/boltz2_conf.ckpt"),
    ("boltz2_aff.ckpt", "https://huggingface.co/boltz-community/boltz-2/resolve/main/boltz2_aff.ckpt"),
    ("mols.tar", "https://huggingface.co/boltz-community/boltz-2/resolve/main/mols.tar"),
]:
    dest = os.path.join(cache, name)
    if not dl_chunked(url, dest):
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
urllib.request.urlretrieve(base + "score_candidates_incr_v12.py", "/nova/score_candidates_incr_v12.py")
urllib.request.urlretrieve(base + "${CAND_FILE}", "/nova/candidates.tsv")
print("fetched scorer + candidates")
PY

echo "FETCHED"; wc -l /nova/candidates.tsv
python3 /nova/score_candidates_incr_v12.py --candidates /nova/candidates.tsv --out "/nova/scores_rxn${RXN_ID}.tsv" --target P40261 --limit "${LIMIT}" --offset "${OFFSET}" 2>&1 \
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
