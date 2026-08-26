"""
Boltz-2 pre-screener for NOVA SN68.

Replicates the validator's molecule scoring exactly:
  score = (affinity_probability_binary - affinity_pred_value) / heavy_atom_count
using Boltz-2 with the validator's config (seed 68, recycling 3, sampling 100,
diffusion_samples_affinity 3, affinity_mw_correction=true), target P40261 clip [2,260].

Reads a TSV of candidates (name\tsmiles), writes scores to a TSV.
"""
import os
import sys
import json
import argparse
import tempfile
import hashlib

NOVA_DIR = "/nova"
sys.path.insert(0, NOVA_DIR)
sys.path.insert(0, os.path.join(NOVA_DIR, "external_tools", "boltz", "src"))

os.environ.setdefault("CUBLAS_WORKSPACE_CONFIG", ":4096:8")
os.environ.setdefault("OMP_NUM_THREADS", "1")
os.environ.setdefault("MKL_NUM_THREADS", "1")
os.environ.setdefault("NUMEXPR_NUM_THREADS", "1")

import torch
try:
    import omegaconf
    torch.serialization.add_safe_globals([omegaconf.dictconfig.DictConfig, omegaconf.listconfig.ListConfig])
except Exception as _e:
    pass
import yaml


def heavy_count(smiles):
    from rdkit import Chem
    m = Chem.MolFromSmiles(smiles)
    return m.GetNumHeavyAtoms() if m else 0


def get_record_id(rec_id, base_seed=68):
    h = hashlib.sha256(str(rec_id).encode()).digest()
    return (int.from_bytes(h[:8], "little") ^ base_seed) % (2**31 - 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--candidates", required=True, help="TSV name\tsmiles")
    ap.add_argument("--out", required=True)
    ap.add_argument("--target", default="P40261")
    ap.add_argument("--limit", type=int, default=0)
    args = ap.parse_args()

    # Load boltz config
    with open(os.path.join(NOVA_DIR, "config", "boltz_config.yaml")) as f:
        bcfg = yaml.load(f, Loader=yaml.FullLoader)

    # Target sequence (P40261 clip [2,260])
    seq = ("SGFTSKDTYLSHFNPRDYLEKYYKFGSRHSAESQILKHLLKNLFKIFCLDGVKGDLLIDIGSGPTIYQLLSACESFKEIVVTDYSDQNLQELEKWLKKEPEAFDWSPVVTYVCDLEGNRVKGPEKEEKLRQAVKQVLKCDVTQSQPLGAVPLPPADCVLSTLCLDAACPDLPTYCRALRNLGSLLKPGGFLVIMDALKSSYYMIGEQKFSSLPLGREAVEAAVKEAGYTIEWFEVISQSYSSTMANNEGLFSLVARKL")
    msa = os.path.join(NOVA_DIR, "data", "msa_files", args.target + ".a3m")

    # Read candidates
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

    # Write YAML inputs
    tmp = tempfile.mkdtemp(prefix="boltz_")
    input_dir = os.path.join(tmp, "inputs")
    output_dir = os.path.join(tmp, "outputs")
    os.makedirs(input_dir, exist_ok=True)
    os.makedirs(output_dir, exist_ok=True)

    id_map = {}  # mol_idx -> (name, smiles)
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

    from boltz.main import predict
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
    )

    # Collect scores
    pred_root = os.path.join(output_dir, "boltz_results_inputs", "predictions")
    results = []
    for mol_idx, (name, smiles) in id_map.items():
        pdir = os.path.join(pred_root, f"{mol_idx}_{args.target}")
        metrics = {}
        if os.path.isdir(pdir):
            for fn in os.listdir(pdir):
                if fn.startswith("affinity") or fn.startswith("confidence"):
                    try:
                        with open(os.path.join(pdir, fn)) as f:
                            metrics.update(json.load(f))
                    except Exception:
                        pass
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


if __name__ == "__main__":
    main()
