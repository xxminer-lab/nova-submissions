#!/bin/bash
# BoltzGen feasibility probe runner v2 for Modal (B200, cuda13).
# Clones UPSTREAM metanova-labs/nova (byte-identical to my vendored tree),
# installs boltzgen, fetches the probe script from my submissions repo, runs it.
set -e
echo "BOLTZGEN_PROBE_BOOT v2"
mkdir -p /nova
cd /tmp
python3 - <<'PY'
import urllib.request, tarfile, io
d = urllib.request.urlopen("https://codeload.github.com/metanova-labs/nova/tar.gz/refs/heads/main").read()
tarfile.open(fileobj=io.BytesIO(d), mode="r:gz").extractall(".")
print("upstream repo extracted")
PY
cp -r nova-main/. /nova/ 2>/dev/null || cp -r nova-main/* /nova/
mkdir -p /nova/mining
python3 - <<'PY'
import urllib.request
u = urllib.request.urlopen("https://raw.githubusercontent.com/xxminer-lab/nova-submissions/main/mining/boltzgen_probe.py").read()
open("/nova/mining/boltzgen_probe.py", "wb").write(u)
print("probe script fetched")
PY

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
