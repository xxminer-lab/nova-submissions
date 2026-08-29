"""Directed SAR analog generator for NOVA SN68.

Random biased-gen seeds are plateaued: the high tail of the random
reactant-combination distribution is mined out. This generator instead walks
the SAR neighborhood of PROVEN strong binders: for each top-K bank hit of a
reaction, it holds all-but-one reactants fixed and swaps the remaining one for
Tanimoto-similar (and optionally random) members of the small reactant pool,
then re-enumerates the product.

Output rows: name<TAB>smiles<TAB>heuristic  (same schema as biased_gen.py)
"""
import os, sys, argparse, random
BASE = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.append(BASE)
from rdkit import Chem
from rdkit.Chem import AllChem, DataStructs
import numpy as np
from mining.molecule_pipeline import (
    get_reaction_smarts, get_molecules_for_role, react, passes_filters,
    heuristic_score,
)

FP_RADIUS = 2
FP_NBITS = 2048


def morgan(smi):
    m = Chem.MolFromSmiles(smi)
    if not m:
        return None
    return AllChem.GetMorganFingerprintAsBitVect(m, FP_RADIUS, nBits=FP_NBITS)


def load_bank_top(bank_path, topk):
    import csv
    rows = [r for r in csv.DictReader(open(bank_path), delimiter="\t") if r.get("score")]
    rows.sort(key=lambda r: float(r["score"]), reverse=True)
    return rows[:topk]


def parse_name(name):
    # rxn:N:a:b or rxn:N:a:b:c
    parts = name.split(":")
    return [int(x) for x in parts[2:]]


def pool_with_fps(role, max_heavy):
    rows = get_molecules_for_role(role)
    out = []
    for mol_id, smi, mask in rows:
        m = Chem.MolFromSmiles(smi)
        if not m or m.GetNumHeavyAtoms() > max_heavy:
            continue
        fp = morgan(smi)
        if fp is not None:
            out.append((mol_id, smi, mask, fp))
    return out


def neighbors(pool, orig_fp, sim_thresh, per_pos, rng, random_frac=0.15):
    """Top-similar pool members to orig_fp, plus a small random tail."""
    sims = []
    for entry in pool:
        s = DataStructs.TanimotoSimilarity(orig_fp, entry[3])
        if s >= sim_thresh:
            sims.append((s, entry))
    sims.sort(key=lambda x: x[0], reverse=True)
    picked = [e for _, e in sims[: max(1, int(per_pos * (1 - random_frac)))]]
    n_rand = min(per_pos - len(picked), max(0, int(per_pos * random_frac)))
    if n_rand:
        picked += rng.sample(pool, min(n_rand, len(pool)))
    return picked[:per_pos]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rxn", type=int, required=True)
    ap.add_argument("--topk", type=int, default=50)
    ap.add_argument("--per-pos", type=int, default=120)
    ap.add_argument("--max-heavy", type=int, default=16)
    ap.add_argument("--sim-thresh", type=float, default=0.35)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    rng = random.Random(args.seed)
    bank_path = os.path.join(os.path.dirname(__file__), f"boltz_scores_rxn{args.rxn}.tsv")
    top = load_bank_top(bank_path, args.topk)
    print(f"loaded top-{len(top)} bank hits for rxn {args.rxn}")

    smarts, roleA, roleB, roleC = get_reaction_smarts(args.rxn)
    roles = [roleA, roleB] + ([roleC] if roleC else [])
    pools = [pool_with_fps(r, args.max_heavy) for r in roles]
    for i, p in enumerate(pools):
        print(f"  pool {i} (heavy<={args.max_heavy}): {len(p)}")
    # full-pool lookup (any size) so original hit reactants always resolve for FP
    full = [pool_with_fps(r, 10**9) for r in roles]
    by_id = [{e[0]: e for e in p} for p in full]


    bank_names = set()
    import csv
    for r in csv.DictReader(open(bank_path), delimiter="\t"):
        bank_names.add(r["name"])

    out, seen_keys = [], set()
    n_tried = 0
    for hit in top:
        ids = parse_name(hit["name"])
        if len(ids) != len(roles):
            continue
        orig_entries = [by_id[i].get(ids[i]) for i in range(len(ids))]
        for pos in range(len(ids)):
            orig = orig_entries[pos]
            if orig is None:
                continue
            swaps = neighbors(pools[pos], orig[3], args.sim_thresh, args.per_pos, rng)
            for sw in swaps:
                if sw[0] == ids[pos]:
                    continue
                new_ids = list(ids)
                new_ids[pos] = sw[0]
                entries = [by_id[i].get(new_ids[i]) for i in range(len(new_ids))]
                if any(e is None for e in entries):
                    continue
                name = "rxn:" + ":".join([str(args.rxn)] + [str(i) for i in new_ids])
                if name in bank_names:
                    continue
                n_tried += 1
                triples = [(e[0], e[1], e[2]) for e in entries]
                smi = react(args.rxn, smarts, *triples)
                if not smi:
                    continue
                m = Chem.MolFromSmiles(smi)
                if not m:
                    continue
                key = Chem.MolToInchiKey(m)
                if key in seen_keys:
                    continue
                seen_keys.add(key)
                ok, reason, _ = passes_filters(smi)
                if not ok:
                    continue
                out.append((name, smi))

    print(f"tried {n_tried} combos -> {len(out)} valid unique products")
    scored = [(n, s, heuristic_score(s)) for n, s in out]
    scored.sort(key=lambda x: x[2], reverse=True)
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "w") as f:
        f.write("name\tsmiles\theuristic\n")
        for n, s, sc in scored:
            f.write(f"{n}\t{s}\t{sc:.6f}\n")
    if scored:
        hv = [Chem.MolFromSmiles(s).GetNumHeavyAtoms() for _, s, _ in scored]
        print(f"  heavy: min={min(hv)} p25={int(np.percentile(hv,25))} median={int(np.median(hv))} max={max(hv)}")
    print(f"  wrote {len(scored)} candidates to {args.out}")


if __name__ == "__main__":
    main()
