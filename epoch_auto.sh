#!/bin/bash
# Epoch-agnostic NOVA auto-submitter (singleton via PID file).
# Watches for the NEXT epoch, detects its reaction, builds+encrypts+stages the
# matching payload, commits on-chain early. Runs one epoch then exits.
# Writes its own PID to a pidfile and a done-marker on success so the master
# loop can supervise WITHOUT fragile pgrep matching.
PY=/var/lib/harness/sn68/.venv/bin/python
cd /var/lib/harness/sn68
set -a; . ./.env 2>/dev/null; set +a

PIDFILE=/tmp/sn68_epoch_auto.pid
DONEFILE=/tmp/sn68_epoch_auto.done

# Singleton: if a live epoch_auto already holds the pidfile, exit quietly.
if [ -f "$PIDFILE" ]; then
  OLDPID=$(cat "$PIDFILE" 2>/dev/null)
  if [ -n "$OLDPID" ] && kill -0 "$OLDPID" 2>/dev/null; then
    exit 0
  fi
fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT

# Determine current epoch, target = current+1
CUR=$($PY nova/mining/epoch_tracker.py --json 2>/dev/null | grep -o '"epoch_index": [0-9]*' | grep -o '[0-9]*')
TARGET=$((CUR+1))
LOG=/var/lib/harness/sn68/auto_submit_${TARGET}.log
RXNFILE=/var/lib/harness/sn68/nova/mining/epoch_${TARGET}_reaction.txt
rm -f "$RXNFILE"
echo "$(date +%H:%M:%S) auto-submit for epoch $TARGET (current=$CUR, pid $$), waiting for rollover" >> "$LOG"
# Wait for rollover
for i in $(seq 1 720); do
  E=$($PY nova/mining/epoch_tracker.py --json 2>/dev/null | grep -o '"epoch_index": [0-9]*' | grep -o '[0-9]*')
  if [ "$E" = "$TARGET" ]; then
    R=$($PY nova/mining/epoch_tracker.py 2>/dev/null | grep 'allowed_reaction (this)' | grep -o 'rxn:[0-9]*')
    echo "$R" > "$RXNFILE"
    echo "$(date +%H:%M:%S) EPOCH $TARGET STARTED reaction=$R" >> "$LOG"
    break
  fi
  sleep 10
done
[ -f "$RXNFILE" ] || { echo "$(date +%H:%M:%S) TIMEOUT waiting for epoch $TARGET" >> "$LOG"; exit 1; }
RXN=$(cat "$RXNFILE" | tr -d '[:space:]'); RNUM=${RXN#rxn:}
# Archive-clean this reaction's bank against the LIVE archive (validators fetch a
# fresh archive at scoring; my own past submissions invalidate repeats once the
# archive catches up). ~90s, affordable inside the 361-block window.
$PY nova/mining/filter_bank_archive.py $RNUM >>"$LOG" 2>&1 \
  && cp nova/mining/boltz_scores_rxn${RNUM}_clean.tsv nova/mining/boltz_scores_rxn${RNUM}.tsv \
  && echo "$(date +%H:%M:%S) bank archive-cleaned for $RXN" >> "$LOG"
# Build payload
$PY nova/mining/build_submission.py --rxn $RNUM --scores nova/mining/boltz_scores_rxn${RNUM}.tsv --out /tmp/payload_${TARGET}_rxn${RNUM}.json >>"$LOG" 2>&1
MOLS=$($PY -c "import json;d=json.load(open('/tmp/payload_${TARGET}_rxn${RNUM}.json'));print(d['payload'].split('|')[0])" 2>>"$LOG")
[ -n "$MOLS" ] || { echo "$(date +%H:%M:%S) BUILD FAILED for $RXN" >> "$LOG"; exit 1; }
echo "$(date +%H:%M:%S) built payload for $RXN (${#MOLS} chars)" >> "$LOG"
# Fresh per-epoch nanobody lottery ticket (seed=epoch so it is unique vs the archive;
# "~" forfeits the 40% nanobody category, a candidate costs nothing and can only win)
NANO=$($PY nova/mining/nanobody_gen.py --n 1 --seed $TARGET --out /tmp/nano_${TARGET}.txt >>"$LOG" 2>&1 && head -1 /tmp/nano_${TARGET}.txt 2>/dev/null)
[ -n "$NANO" ] || NANO="~"
echo "$(date +%H:%M:%S) nanobody: ${#NANO} chars" >> "$LOG"
# Encrypt + stage (derive CURRENT uid dynamically — re-registration changes uid,
# and the validator's decrypt() rejects a payload whose {uid}: prefix mismatches)
MYUID=$($PY nova/mining/current_uid.py 2>>"$LOG")
# Auto-recover from a prune: re-register (burn) and re-lookup, up to 2 tries.
if [ -z "$MYUID" ]; then
  for regtry in 1 2; do
    echo "$(date +%H:%M:%S) UNREGISTERED (pruned?) — re-registering (try $regtry)" >> "$LOG"
    curl -s --unix-socket /run/harness/wallet.sock -X POST http://localhost/register -H 'Content-Type: application/json' -d '{"netuid":68,"hotkeyIndex":0,"maxCostTao":0.25}' >> "$LOG" 2>&1
    echo "" >> "$LOG"
    MYUID=$($PY nova/mining/current_uid.py 2>>"$LOG")
    [ -n "$MYUID" ] && break
  done
fi
[ -n "$MYUID" ] || { echo "$(date +%H:%M:%S) UID LOOKUP FAILED after re-register attempts" >> "$LOG"; exit 1; }
echo "$(date +%H:%M:%S) current uid=$MYUID" >> "$LOG"
POINTER=$($PY nova/mining/prepare_commit.py --molecules "$MOLS" --nanobody "$NANO" --uid "$MYUID" 2>>"$LOG" | grep '^POINTER=' | cut -d= -f2)
[ -n "$POINTER" ] || { echo "$(date +%H:%M:%S) PREPARE FAILED" >> "$LOG"; exit 1; }
echo "$(date +%H:%M:%S) staged pointer=$POINTER" >> "$LOG"
# Commit on-chain
for i in $(seq 1 200); do
  RESP=$(curl -s --unix-socket /run/harness/wallet.sock -X POST http://localhost/set-commitment -H 'Content-Type: application/json' -d "{\"netuid\":68,\"hotkeyIndex\":0,\"pointer\":\"$POINTER\"}" 2>&1)
  echo "$(date +%H:%M:%S) attempt $i: $RESP" >> "$LOG"
  if echo "$RESP" | grep -q '"ok":true'; then
    echo "$(date +%H:%M:%S) SUCCESS epoch=$TARGET pointer=$POINTER" >> "$LOG"
    echo "$TARGET" > "$DONEFILE"
    exit 0
  fi
  sleep 6
done
echo "$(date +%H:%M:%S) EXHAUSTED without success" >> "$LOG"; exit 1
