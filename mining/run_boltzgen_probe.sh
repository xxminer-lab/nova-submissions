#!/bin/bash
# BoltzGen feasibility probe runner for Modal (B200, cuda13).
# Clones the nova tree, installs boltzgen, runs the wrapper probe on 4 sequences.
set -e
echo "BOLTZGEN_PROBE_BOOT"
mkdir -p /nova
cd /tmp
python3 - <<'PY'
import urllib.request, tarfile, io
d = urllib.request.urlopen("https://codeload.github.com/xxminer-lab/nova-submissions/tar.gz/refs/heads/main").read()
tarfile.open(fileobj=io.BytesIO(d), mode="r:gz").extractall(".")
print("repo extracted")
PY
cp -r nova-submissions-main/. /nova/ 2>/dev/null || cp -r nova-submissions-main/* /nova/

echo "installing torch"
pip install "torch==2.7.1" 2>&1 | tail -2
echo "installing boltzgen"
cd /nova/external_tools/boltzgen
pip install . 2>&1 | tail -4
python3 -c "import boltzgen; print('boltzgen import OK')"

echo "PROBE_RUN"
cd /nova
python3 /nova/mining/boltzgen_probe.py 2>&1 | grep -E "===|PROBE|Error|Traceback|error|\.\.\." | tail -40
echo "PROBE_DONE"
