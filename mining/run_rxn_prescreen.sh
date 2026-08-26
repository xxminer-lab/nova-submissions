#!/bin/bash
# Self-contained NOVA Boltz-2 pre-screen bootstrap for Modal.
# Usage: run_rxn_prescreen.sh <RXN_ID> <LIMIT>
# Fetches repo + scorer + candidates, installs deps, runs scorer, prints sorted top hits.
set -e
RXN_ID="${1:-2}"
LIMIT="${2:-400}"
echo "BOOTSTRAP rxn=${RXN_ID} limit=${LIMIT}"

pip install -q torch omegaconf pyyaml rdkit-pypi numpy scipy pandas requests biopython fair-esm 2>&1 | tail -2 || true

mkdir -p /nova
cd /tmp
python3 - <<'PY'
import urllib.request, tarfile, io
d = urllib.request.urlopen("https://codeload.github.com/metanova-labs/nova/tar.gz/refs/heads/main").read()
tarfile.open(fileobj=io.BytesIO(d), mode="r:gz").extractall(".")
print("repo extracted")
PY
cp -r nova-main/. /nova/ 2>/dev/null || cp -r nova-main/* /nova/

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
import csv
rows = list(csv.DictReader(open("/nova/scores_rxn${RXN_ID}.tsv"), delimiter="\t"))
rows = [r for r in rows if r.get("score") not in (None, "", "None")]
rows.sort(key=lambda r: float(r["score"]), reverse=True)
print("=== TOP 25 rxn${RXN_ID} ===")
for r in rows[:25]:
    print(r["name"], r["score"])
PY
