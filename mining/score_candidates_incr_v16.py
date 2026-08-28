"""
Boltz-2 pre-screener for NOVA SN68 — v13 BATCHED-SUBPROCESS edition.

ROOT CAUSE FIX for the systemic "Wrote N YAML inputs" stall: v11/v12 issued ONE
boltz.main.predict() call over all 120 molecules in-process. That call hangs
silently (0 SCORE) regardless of num_workers (0 or 4) and no_kernels (True/False).
v13 instead runs predict() in a SEPARATE SUBPROCESS per batch of B molecules
(default 12). Each subprocess is given a hard wall-clock timeout; if it hangs it
is killed and that batch is skipped, so one pathological molecule can no longer
freeze the whole job. Scores are collected after EVERY batch and printed as
one-line SCORE records (flush=True), so partial results survive a timeout kill.

Score = (affinity_probability_binary - affinity_pred_value) / heavy_atom_count
Boltz-2 config: seed 68, recycling 3, sampling 100, diffusion_samples_affinity 3,
affinity_mw_correction=true, target P40261.
"""
import os
import sys
import json
import argparse
import tempfile
import hashlib
import subprocess
import time

NOVA_DIR = os.environ.get("NOVA_DIR", "/nova")
sys.path.insert(0, NOVA_DIR)
sys.path.insert(0, os.path.join(NOVA_DIR, "external_tools", "boltz", "src"))

os.environ.setdefault("CUBLAS_WORKSPACE_CONFIG", ":4096:8")
os.environ.setdefault("OMP_NUM_THREADS", "1")
os.environ.setdefault("MKL_NUM_THREADS", "1")
os.environ.setdefault("NUMEXPR_NUM_THREADS", "1")
os.environ["TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD"] = "1"

import yaml


def heavy_count(smiles):
    from rdkit import Chem
    m = Chem.MolFromSmiles(smiles)
    return m.GetNumHeavyAtoms() if m else 0


def get_record_id(rec_id, base_seed=68):
    h = hashlib.sha256(str(rec_id).encode()).digest()
    return (int.from_bytes(h[:8], "little") ^ base_seed) % (2**31 - 1)


def read_metrics(pdir):
    metrics = {}
    if os.path.isdir(pdir):
        for fn in os.listdir(pdir):
            if fn.startswith("affinity") or fn.startswith("confidence"):
                try:
                    with open(os.path.join(pdir, fn)) as f:
                        metrics.update(json.load(f))
                except Exception:
                    pass
    return metrics


# ---- worker: runs inside the subprocess, one batch of YAMLs ----
WORKER_SRC = r'''
import os, sys, json, argparse
NOVA_DIR = os.environ.get("NOVA_DIR", "/nova")
sys.path.insert(0, NOVA_DIR)
sys.path.insert(0, os.path.join(NOVA_DIR, "external_tools", "boltz", "src"))
os.environ.setdefault("CUBLAS_WORKSPACE_CONFIG", ":4096:8")
os.environ.setdefault("OMP_NUM_THREADS", "1")
os.environ.setdefault("MKL_NUM_THREADS", "1")
os.environ.setdefault("NUMEXPR_NUM_THREADS", "1")
os.environ["TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD"] = "1"
import torch
try:
    import omegaconf
    from omegaconf import dictconfig, listconfig, base as _ob
    _g = [dictconfig.DictConfig, listconfig.ListConfig, _ob.ContainerMetadata]
    try:
        from omegaconf.nodes import ValueNode
        _g.append(ValueNode)
    except Exception:
        pass
    try:
        from omegaconf.base import Metadata
        _g.append(Metadata)
    except Exception:
        pass
    torch.serialization.add_safe_globals(_g)
except Exception:
    pass
import yaml
ap = argparse.ArgumentParser()
ap.add_argument("--input-dir", required=True)
ap.add_argument("--out-dir", required=True)
args = ap.parse_args()
with open(os.path.join(NOVA_DIR, "config", "boltz_config.yaml")) as f:
    bcfg = yaml.load(f, Loader=yaml.FullLoader)
from boltz.main import predict
predict(
    data=args.input_dir,
    out_dir=args.out_dir,
    recycling_steps=bcfg["recycling_steps"],
    sampling_steps=bcfg["sampling_steps"],
    diffusion_samples=bcfg["diffusion_samples"],
    sampling_steps_affinity=bcfg["sampling_steps_affinity"],
    diffusion_samples_affinity=bcfg["diffusion_samples_affinity"],
    output_format=bcfg["output_format"],
    seed=68,
    affinity_mw_correction=bcfg["affinity_mw_correction"],
    override=True,
    num_workers=0,
    no_kernels=True,
)
print("WORKER_DONE", flush=True)
'''


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--candidates", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--target", default="P40261")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--offset", type=int, default=0)
    ap.add_argument("--batch-size", type=int, default=12)
    ap.add_argument("--batch-timeout", type=int, default=1200)
    args = ap.parse_args()
    target = args.target

    seq = ("SGFTSKDTYLSHFNPRDYLEKYYKFGSRHSAESQILKHLLKNLFKIFCLDGVKGDLLIDIGSGPTIYQLLSACESFKEIVVTDYSDQNLQELEKWLKKEPEAFDWSPVVTYVCDLEGNRVKGPEKEEKLRQAVKQVLKCDVTQSQPLGAVPLPPADCVLSTLCLDAACPDLPTYCRALRNLGSLLKPGGFLVIMDALKSSYYMIGEQKFSSLPLGREAVEAAVKEAGYTIEWFEVISQSYSSTMANNEGLFSLVARKL")
    msa = os.path.join(NOVA_DIR, "data", "msa_files", target + ".a3m")

    rows = []
    with open(args.candidates) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("name\t"):
                continue
            parts = line.split("\t")
            if len(parts) >= 2:
                rows.append((parts[0], parts[1]))
    if args.offset:
        rows = rows[args.offset:]
    if args.limit:
        rows = rows[: args.limit]
    print(f"Scoring {len(rows)} candidates (offset={args.offset}, limit={args.limit}, batch={args.batch_size})", flush=True)

    # write worker script once
    worker_path = os.path.join(NOVA_DIR, "_boltz_worker.py")
    with open(worker_path, "w") as f:
        f.write(WORKER_SRC)

    tmp = tempfile.mkdtemp(prefix="boltz_")
    output_dir = os.path.join(tmp, "outputs")
    os.makedirs(output_dir, exist_ok=True)

    # build (mol_idx, name, smiles, yaml_text) list with embed pre-filter
    entries = []
    skipped = 0
    for name, smiles in rows:
        try:
            from rdkit import Chem
            from rdkit.Chem import AllChem
            _m = Chem.MolFromSmiles(smiles)
            if _m is None:
                skipped += 1
                continue
            _mh = Chem.AddHs(_m)
            if AllChem.EmbedMolecule(_mh, randomSeed=42) != 0:
                skipped += 1
                continue
        except Exception:
            skipped += 1
            continue
        mol_idx = get_record_id(smiles, 68)
        data = {
            "version": 1,
            "sequences": [
                {"protein": {"id": "A", "sequence": seq, "msa": msa}},
                {"ligand": {"id": "B", "smiles": smiles}},
            ],
            "properties": [{"affinity": {"binder": "B"}}],
        }
        ytext = yaml.safe_dump(data, sort_keys=False, default_flow_style=False)
        entries.append((mol_idx, name, smiles, ytext))
    print(f"Prepared {len(entries)} molecules (skipped {skipped} unembeddable)", flush=True)

    results = {}  # mol_idx -> (name, smiles, ha, apb, apv, score)
    B = max(1, args.batch_size)
    nb = (len(entries) + B - 1) // B
    for bi in range(nb):
        chunk = entries[bi * B:(bi + 1) * B]
        b_in = os.path.join(tmp, f"in_{bi}")
        b_out = os.path.join(output_dir, f"out_{bi}")
        os.makedirs(b_in, exist_ok=True)
        os.makedirs(b_out, exist_ok=True)
        for mol_idx, name, smiles, ytext in chunk:
            with open(os.path.join(b_in, f"{mol_idx}_{target}.yaml"), "w") as f:
                f.write(ytext)
        t0 = time.time()
        # v16: log the batch's molecules up-front so a hang identifies the culprit chemotype
        print(f"BATCH_START {bi+1}/{nb} mols=" + ",".join(n for _i, n, _s, _y in chunk), flush=True)
        err_path = os.path.join(tmp, f"err_{bi}.log")
        err_f = open(err_path, "wb")
        proc = subprocess.Popen(
            [sys.executable, worker_path, "--input-dir", b_in, "--out-dir", b_out],
            stdout=err_f, stderr=err_f, start_new_session=True,
        )
        try:
            proc.wait(timeout=args.batch_timeout)
            err_f.close()
            status = "ok" if proc.returncode == 0 else f"rc={proc.returncode}"
            if proc.returncode != 0:
                try:
                    with open(err_path, "rb") as ef:
                        tail = ef.read().decode(errors="replace").strip().splitlines()
                    for el in tail[-6:]:
                        print(f"WORKER_ERR b{bi}: {el[:200]}", flush=True)
                except Exception:
                    pass
        except subprocess.TimeoutExpired:
            # kill the whole process group (worker + any boltz children)
            try:
                import signal as _sig
                os.killpg(os.getpgid(proc.pid), _sig.SIGKILL)
            except Exception:
                try:
                    proc.kill()
                except Exception:
                    pass
            try:
                proc.wait(timeout=10)
                status = "TIMEOUT_KILLED"
            except Exception:
                status = "TIMEOUT_UNREAPABLE"
            err_f.close()
            try:
                with open(err_path, "rb") as ef:
                    tail = ef.read().decode(errors="replace").strip().splitlines()
                for el in tail[-6:]:
                    print(f"WORKER_ERR b{bi}: {el[:200]}", flush=True)
            except Exception:
                pass
        # collect whatever this batch produced
        pred_root = os.path.join(b_out, "boltz_results_in_%d" % bi, "predictions")
        if not os.path.isdir(pred_root):
            # boltz names results dir after the input dir basename
            for cand in os.listdir(b_out) if os.path.isdir(b_out) else []:
                if cand.startswith("boltz_results_"):
                    pr = os.path.join(b_out, cand, "predictions")
                    if os.path.isdir(pr):
                        pred_root = pr
                        break
        got = 0
        for mol_idx, name, smiles, _y in chunk:
            pdir = os.path.join(pred_root, f"{mol_idx}_{target}")
            metrics = read_metrics(pdir)
            apb = metrics.get("affinity_probability_binary")
            apv = metrics.get("affinity_pred_value")
            ha = heavy_count(smiles)
            score = (apb - apv) / ha if (apb is not None and apv is not None and ha) else None
            results[mol_idx] = (name, smiles, ha, apb, apv, score)
            if score is not None:
                got += 1
                print(f"SCORE\t{name}\t{smiles}\t{ha}\t{apb}\t{apv}\t{score}", flush=True)
        print(f"BATCH {bi+1}/{nb} {status} got={got}/{len(chunk)} elapsed={time.time()-t0:.0f}s", flush=True)

    with open(args.out, "w") as f:
        f.write("name\tsmiles\theavy\tprob_binary\tpred_value\tscore\n")
        for mol_idx, (name, smiles, ha, apb, apv, score) in results.items():
            f.write(f"{name}\t{smiles}\t{ha}\t{apb}\t{apv}\t{score}\n")
    scored = [r for r in results.values() if r[5] is not None]
    print(f"Scored {len(scored)}/{len(results)} candidates -> {args.out}", flush=True)
    print("SCORES_DONE", flush=True)


if __name__ == "__main__":
    main()
