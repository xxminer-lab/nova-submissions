"""
Boltz-2 pre-screener for NOVA SN68 with INCREMENTAL score emission.

Replicates the validator's molecule scoring exactly:
  score = (affinity_probability_binary - affinity_pred_value) / heavy_atom_count
using Boltz-2 with the validator's config (seed 68, recycling 3, sampling 100,
diffusion_samples_affinity 3, affinity_mw_correction=true), target P40261 clip [2,260].

KEY RELIABILITY FIX: a background monitor thread tails the Boltz predictions
directory while predict() runs and prints each newly-scored molecule as a
one-line SCORE record to stdout (flush=True). Since ModalLogs captures stdout,
we can retrieve PARTIAL scores even if the job hits its timeout and is killed.
This avoids the prior failure mode where 400-molecule jobs died at the timeout
with zero scores recovered.

Reads a TSV of candidates (name\tsmiles), writes scores to a TSV at the end AND
streams them incrementally as: SCORE\tname\tsmiles\theavy\tprob\tpred\tscore
"""
import os
import sys
import json
import argparse
import tempfile
import hashlib
import threading
import time

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


def monitor_predictions(pred_root, id_map, stop_event, interval=20):
    """Background thread: emit SCORE lines for newly-completed molecules."""
    emitted = set()
    while not stop_event.is_set():
        for mol_idx, (name, smiles) in id_map.items():
            if mol_idx in emitted:
                continue
            pdir = os.path.join(pred_root, f"{mol_idx}_{TARGET}")
            metrics = read_metrics(pdir)
            apb = metrics.get("affinity_probability_binary")
            apv = metrics.get("affinity_pred_value")
            if apb is None or apv is None:
                continue
            ha = heavy_count(smiles)
            score = (apb - apv) / ha if ha else None
            emitted.add(mol_idx)
            print(f"SCORE\t{name}\t{smiles}\t{ha}\t{apb}\t{apv}\t{score}", flush=True)
        stop_event.wait(interval)


TARGET = "P40261"


def main():
    global TARGET
    ap = argparse.ArgumentParser()
    ap.add_argument("--candidates", required=True, help="TSV name\tsmiles")
    ap.add_argument("--out", required=True)
    ap.add_argument("--target", default="P40261")
    ap.add_argument("--limit", type=int, default=0)
    args = ap.parse_args()
    TARGET = args.target

    with open(os.path.join(NOVA_DIR, "config", "boltz_config.yaml")) as f:
        bcfg = yaml.load(f, Loader=yaml.FullLoader)

    seq = ("SGFTSKDTYLSHFNPRDYLEKYYKFGSRHSAESQILKHLLKNLFKIFCLDGVKGDLLIDIGSGPTIYQLLSACESFKEIVVTDYSDQNLQELEKWLKKEPEAFDWSPVVTYVCDLEGNRVKGPEKEEKLRQAVKQVLKCDVTQSQPLGAVPLPPADCVLSTLCLDAACPDLPTYCRALRNLGSLLKPGGFLVIMDALKSSYYMIGEQKFSSLPLGREAVEAAVKEAGYTIEWFEVISQSYSSTMANNEGLFSLVARKL")
    msa = os.path.join(NOVA_DIR, "data", "msa_files", args.target + ".a3m")

    rows = []
    with open(args.candidates) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("name\t"):
                continue
            parts = line.split("\t")
            if len(parts) >= 2:
                rows.append((parts[0], parts[1]))
    if args.limit:
        rows = rows[: args.limit]
    print(f"Scoring {len(rows)} candidates", flush=True)

    tmp = tempfile.mkdtemp(prefix="boltz_")
    input_dir = os.path.join(tmp, "inputs")
    output_dir = os.path.join(tmp, "outputs")
    os.makedirs(input_dir, exist_ok=True)
    os.makedirs(output_dir, exist_ok=True)

    id_map = {}
    for name, smiles in rows:
        mol_idx = get_record_id(smiles, 68)
        id_map[mol_idx] = (name, smiles)
        data = {
            "version": 1,
            "sequences": [
                {"protein": {"id": "A", "sequence": seq, "msa": msa}},
                {"ligand": {"id": "B", "smiles": smiles}},
            ],
            "properties": [{"affinity": {"binder": "B"}}],
        }
        with open(os.path.join(input_dir, f"{mol_idx}_{args.target}.yaml"), "w") as f:
            f.write(yaml.safe_dump(data, sort_keys=False, default_flow_style=False))

    print(f"Wrote {len(id_map)} YAML inputs", flush=True)

    pred_root = os.path.join(output_dir, "boltz_results_inputs", "predictions")
    stop_event = threading.Event()
    mon = threading.Thread(target=monitor_predictions, args=(pred_root, id_map, stop_event), daemon=True)
    mon.start()

    from boltz.main import predict
    try:
        predict(
            data=input_dir,
            out_dir=output_dir,
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
    finally:
        stop_event.set()
        mon.join(timeout=5)

    # Final collection (dedup with what monitor emitted is fine; rewrite full file)
    results = []
    for mol_idx, (name, smiles) in id_map.items():
        pdir = os.path.join(pred_root, f"{mol_idx}_{args.target}")
        metrics = read_metrics(pdir)
        apb = metrics.get("affinity_probability_binary")
        apv = metrics.get("affinity_pred_value")
        ha = heavy_count(smiles)
        score = None
        if apb is not None and apv is not None and ha:
            score = (apb - apv) / ha
        results.append((name, smiles, ha, apb, apv, score))

    with open(args.out, "w") as f:
        f.write("name\tsmiles\theavy\tprob_binary\tpred_value\tscore\n")
        for name, smiles, ha, apb, apv, score in results:
            f.write(f"{name}\t{smiles}\t{ha}\t{apb}\t{apv}\t{score}\n")
    scored = [r for r in results if r[5] is not None]
    print(f"Scored {len(scored)}/{len(results)} candidates -> {args.out}", flush=True)
    print("SCORES_DONE", flush=True)


if __name__ == "__main__":
    main()
