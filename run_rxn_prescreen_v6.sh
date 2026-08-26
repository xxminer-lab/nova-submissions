#!/bin/bash
# FAST NOVA Boltz-2 pre-screen bootstrap for Modal, with PRE-DOWNLOADED weights.
# Usage: run_rxn_prescreen_v6.sh <RXN_ID> <LIMIT>
#
# KEY FIX vs v5: pre-download Boltz-2 weights (boltz2_conf.ckpt, boltz2_aff.ckpt,
# mols.tar) from the model-gateway mirror into the cache BEFORE predict() runs.
# This avoids the HuggingFace download stall that killed v3/v4/v5.
set -e
RXN_ID="${1:-2}"
LIMIT="${2:-400}"
echo "BOOTSTRAP_V6 rxn=${RXN_ID} limit=${LIMIT}"

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

# PRE-DOWNLOAD Boltz-2 weights from the model-gateway mirror (faster than HF).
# predict() checks cache / "boltz2_conf.ckpt" and cache / "boltz2_aff.ckpt" and
# cache / "mols" before downloading; pre-populating them skips the stall.
export BOLTZ_CACHE=/nova/boltz_cache
mkdir -p "$BOLTZ_CACHE"
echo "pre-downloading Boltz-2 weights to $BOLTZ_CACHE"
python3 - <<'PY'
import urllib.request, os, tarfile
cache = os.environ["BOLTZ_CACHE"]
def dl(url, dest, timeout=300):
    if os.path.exists(dest):
        print(f"exists: {dest}")
        return
    print(f"downloading {url} -> {dest}")
    urllib.request.urlretrieve(url, dest)
    print(f"done: {dest} ({os.path.getsize(dest)} bytes)")
# model-gateway mirror first (faster), HF as fallback
for name, urls in [
    ("boltz2_conf.ckpt", ["https://model-gateway.boltz.bio/boltz2_conf.ckpt",
                          "https://huggingface.co/boltz-community/boltz-2/resolve/main/boltz2_conf.ckpt"]),
    ("boltz2_aff.ckpt", ["https://model-gateway.boltz.bio/boltz2_aff.ckpt",
                         "https://huggingface.co/boltz-community/boltz-2/resolve/main/boltz2_aff.ckpt"]),
    ("mols.tar", ["https://huggingface.co/boltz-community/boltz-2/resolve/main/mols.tar"]),
]:
    dest = os.path.join(cache, name)
    for url in urls:
        try:
            dl(url, dest)
            break
        except Exception as e:
            print(f"failed {url}: {e}")
    else:
        raise RuntimeError(f"could not download {name}")
# extract mols.tar -> mols/
mols_dir = os.path.join(cache, "mols")
if not os.path.isdir(mols_dir):
    print("extracting mols.tar")
    with tarfile.open(os.path.join(cache, "mols.tar")) as tar:
        tar.extractall(cache)
print("weights ready:", os.listdir(cache))
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
