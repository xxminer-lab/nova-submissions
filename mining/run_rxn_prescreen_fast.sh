#!/bin/bash
# FAST NOVA Boltz-2 pre-screen bootstrap for Modal.
# Usage: run_rxn_prescreen_fast.sh <RXN_ID> <LIMIT>
#
# The scorer inserts external_tools/boltz/src into sys.path, so boltz does NOT
# need to be built/installed as a wheel - only its DEPENDENCIES do. We extract
# the dep list from pyproject.toml and pip-install just those (+ the two
# undeclared imports pytorch-lightning, omegaconf), skipping the slow boltz
# source build. This is faster and avoids build-toolchain failures.
set -e
RXN_ID="${1:-2}"
LIMIT="${2:-400}"
echo "BOOTSTRAP_FAST rxn=${RXN_ID} limit=${LIMIT}"

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
# Drop wandb (not needed for scoring; avoids login prompts)
deps = [d for d in deps if not d.startswith("wandb")]
print(" ".join('"%s"' % d for d in deps))
PY
DEPS=$(cat /tmp/boltz_deps.txt)
echo "installing deps: $DEPS"
eval pip install $DEPS pytorch-lightning omegaconf 2>&1 | tail -8
echo "PIP_EXIT=${PIPESTATUS[0]}"
python3 -c "import pytorch_lightning, omegaconf, rdkit, einops, fairscale; print('imports OK pl=', pytorch_lightning.__version__)"

cd /nova
python3 - <<PY
import urllib.request
base = "https://raw.githubusercontent.com/xxminer-lab/nova-submissions/main/mining/"
urllib.request.urlretrieve(base + "score_candidates_incr.py", "/nova/score_candidates_incr.py")
urllib.request.urlretrieve(base + "candidates_rxn${RXN_ID}.tsv", "/nova/candidates.tsv")
print("fetched scorer + candidates")
PY

echo "FETCHED"; wc -l /nova/candidates.tsv
python3 /nova/score_candidates_incr.py --candidates /nova/candidates.tsv --out "/nova/scores_rxn${RXN_ID}.tsv" --target P40261 --limit "${LIMIT}" 2>&1 | tail -40
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
