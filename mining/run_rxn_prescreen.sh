#!/bin/bash
# Self-contained NOVA Boltz-2 pre-screen bootstrap for Modal.
# Usage: run_rxn_prescreen.sh <RXN_ID> <LIMIT>
# Fetches repo + scorer + candidates, installs deps, runs scorer, prints sorted top hits.
set -e
RXN_ID="${1:-2}"
LIMIT="${2:-400}"
echo "BOOTSTRAP rxn=${RXN_ID} limit=${LIMIT}"

# Full Boltz dependency stack (from external_tools/boltz/pyproject.toml) PLUS
# pytorch_lightning (imported directly by boltz/main.py but not declared) and
# omegaconf (used by the scorer). Surface pip errors (no || true, no tail) so a
# resolution conflict is visible in the logs instead of silently passing.
pip install \
  "torch>=2.2" "numpy>=1.26,<2.0" hydra-core==1.3.2 "rdkit>=2024.3.2" \
  dm-tree==0.1.8 "requests==2.32.3" "pandas>=2.2.2" types-requests \
  einops==0.8.0 einx==0.3.0 fairscale==0.4.13 mashumaro==3.14 modelcif==1.2 \
  click==8.1.7 pyyaml==6.0.2 biopython==1.84 scipy==1.13.1 numba==0.61.0 \
  gemmi==0.6.5 scikit-learn==1.6.1 chembl_structure_pipeline==1.2.2 \
  pytorch-lightning omegaconf 2>&1 | tail -15
echo "PIP_EXIT=${PIPESTATUS[0]}"
python3 -c "import pytorch_lightning; print('pytorch_lightning OK', pytorch_lightning.__version__)"

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
