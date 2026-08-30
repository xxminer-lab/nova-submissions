#!/bin/bash
# One-command harvest pipeline for a completed NOVA prescreen shard.
# Usage: harvest_shard.sh <JOB_ID> <RXN_ID>
# Pulls raw log from the local modal bridge (x-subnet header), json-parses .logs,
# extracts SCORES_B64_BEGIN/END, decodes to a shard TSV, merges keep-best into the bank.
set -e
JOB_ID="$1"
RXN="$2"
if [ -z "$JOB_ID" ] || [ -z "$RXN" ]; then
  echo "usage: harvest_shard.sh <JOB_ID> <RXN_ID>" >&2; exit 1
fi
MINING=/var/lib/harness/sn68/nova/mining
cd "$MINING"
BANK="boltz_scores_rxn${RXN}.tsv"
SHARD="boltz_scores_rxn${RXN}_job_${JOB_ID##*-}.tsv"
RAW="/tmp/harvest_${JOB_ID}.json"
B64="/tmp/harvest_${JOB_ID}.b64"

echo "[harvest] job=$JOB_ID rxn=$RXN bank=$BANK shard=$SHARD"

# 1. Pull raw log from modal bridge (x-subnet header required), json-parse .logs
curl -s -H "x-subnet: sn68" "http://127.0.0.1:8899/job/${JOB_ID}/logs?tail=600" -o "$RAW"
python3 - "$RAW" "$B64" <<'PY'
import sys, json, re
raw_path, b64_path = sys.argv[1], sys.argv[2]
txt = open(raw_path, errors="replace").read()
# The bridge returns a JSON envelope; extract .logs if present, else use raw text.
logs = txt
try:
    obj = json.loads(txt)
    if isinstance(obj, dict) and "logs" in obj:
        logs = obj["logs"]
except Exception:
    pass
lines = logs.splitlines()
# Find markers
begin = end = None
for i, l in enumerate(lines):
    if "SCORES_B64_BEGIN" in l: begin = i
    if "SCORES_B64_END" in l: end = i
if begin is None or end is None or end <= begin:
    print("[harvest] ERROR: SCORES_B64 markers not found (begin=%s end=%s)" % (begin, end))
    sys.exit(2)
blob_lines = []
for l in lines[begin+1:end]:
    s = l.strip()
    # keep only pure-base64 lines (skip SCORE/DataLoader/TOP-25/status noise)
    if s and re.fullmatch(r"[A-Za-z0-9+/=]+", s):
        blob_lines.append(s)
open(b64_path, "w").write("\n".join(blob_lines) + "\n")
print("[harvest] extracted %d b64 lines" % len(blob_lines))
PY

# 2. Decode b64 -> shard TSV
python3 - "$B64" "$SHARD" <<'PY'
import sys, base64
b64_path, shard_path = sys.argv[1], sys.argv[2]
blob = open(b64_path).read().replace("\n", "").strip()
data = base64.b64decode(blob)
open(shard_path, "wb").write(data)
nlines = data.count(b"\n")
print("[harvest] decoded %d bytes, %d lines -> %s" % (len(data), nlines, shard_path))
PY

# 3. Verify shard header + row count
echo "[harvest] shard head:"; head -1 "$SHARD"
echo "[harvest] shard rows: $(wc -l < "$SHARD")"

# 4. Merge keep-best into bank
python3 merge_keep_best.py "$BANK" "$SHARD" "${BANK}.merged" && mv "${BANK}.merged" "$BANK"

# 4b. Archive-clean the bank (validator rejects archive-InChIKey dupes and
# Tanimoto>=0.7 vs historical with -inf; a dirty top-20 silently collapses
# the epoch score). filter_bank_archive.py writes boltz_scores_rxnN_clean.tsv.
if [ -z "$NO_ARCHIVE_FILTER" ]; then
  /var/lib/harness/sn68/.venv/bin/python filter_bank_archive.py "$RXN" >/dev/null 2>&1 \
    && cp "${BANK%.tsv}_clean.tsv" "$BANK" \
    && echo "[harvest] bank archive-cleaned"
fi

# 5. Report new bank size + top-20 SUM
python3 - "$BANK" <<'PY'
import sys
bank = sys.argv[1]
rows = []
for l in open(bank, errors="replace"):
    p = l.rstrip("\n").split("\t")
    if len(p) >= 6 and p[0] != "name":
        try: rows.append(float(p[5]))
        except: pass
rows.sort(reverse=True)
print("[harvest] FINAL bank=%d top20_SUM=%.4f top1=%.4f" % (len(rows), sum(rows[:20]), rows[0] if rows else 0))
PY
echo "[harvest] DONE rxn=$RXN job=$JOB_ID"
