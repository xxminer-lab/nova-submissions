#!/bin/bash
# Self-contained NOVA Boltz-2 pre-screen bootstrap for Modal.
# Usage: run_rxn_prescreen.sh <RXN_ID> <LIMIT>
#
# Strategy: extract the repo FIRST, then `pip install /nova/external_tools/boltz`
# so pip resolves ALL of boltz's declared dependencies from pyproject.toml
# automatically (no manual 20-package list to drift out of sync). Then add the
# two packages boltz imports but does NOT declare: pytorch-lightning + omegaconf.
set -e
RXN_ID="${1:-2}"
LIMIT="${2:-400}"
echo "BOOTSTRAP rxn=${RXN_ID} limit=${LIMIT}"

mkdir -p /nova
cd /tmp
python3 - <<'PY'
import urllib.request, tarfile, io
d = urllib.request.urlopen("https://codeload.github.com/metanova-labs/nova/tar.gz/refs/heads/main").read()
tarfile.open(fileobj=io.BytesIO(d), mode="r:gz").extractall(".")
print("repo extracted")
PY
cp -r nova-main/. /nova/ 2>/dev/null || cp -r nova-main/* /nova/

# Canonical install: boltz from source (pulls declared deps) + undeclared imports.
# Surface errors; do not mask with || true.
pip install /nova/external_tools/boltz 2>&1 | tail -8
echo "BOLTZ_PIP_EXIT=${PIPESTATUS[0]}"
pip install pytorch-lightning omegaconf 2>&1 | tail -8
echo "EXTRA_PIP_EXIT=${PIPESTATUS[0]}"
python3 -c "import pytorch_lightning, omegaconf; print('imports OK pl=', pytorch_lightning.__version__)"

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
