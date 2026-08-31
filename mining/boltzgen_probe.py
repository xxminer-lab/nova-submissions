#!/usr/bin/env python3
"""BoltzGen feasibility probe for NOVA SN68 nanobody track.

Runs the VALIDATOR'S OWN BoltzgenWrapper (external_tools/boltzgen/src/boltzgen/boltzgen_wrapper.py)
on a handful of nano_sar mutant candidates + 2 archive-top sequences, against IL-6 (P05231/4O9H),
and prints per-sequence metrics so we can judge whether designed mutants can rank top-5 of ~30/epoch.
"""
import os, sys, json

NOVA = "/nova"
sys.path.insert(0, NOVA)

CANDS = [
    # my nano_sar mutants (seed 24810-24813 family + fresh)
    "QVQLVESGGGLVQPGGSLRLSCAASGFTFSSYAMSWVRQAPGKGLEWVSAISGSGGSTYYADSVKGRFTISRDNSKNTLYLQMNSLRAEDTAVYYCAKEFTLANSVHRYSNWGQGTLVTVSS",
    "EVQLVESGGGLVQPGGSLRLSCAASGFTFSSYAMSWVRQAPGKGLEWVSAISGSGGSTYYADSVKGRFTISRDNSKNTLYLQMNSLRAEDTAVYYCAKGEERDYFLSVSEYMSWGQGTLVTVSS",
    "QIENLESGGGLVQPGGSLRLSCAASGYHFSSYVMSWFRQASGKEREFVTAIAWSGGYSFYADSVKGRFTSSRANSKNTFTLQMNSLRAEDTAVYYCAAGGTGVSDISEIYNPSLWQYWGAGSTVTVSR",
    # archive-top reference sequences (known strong metrics)
    "QVENVAVGGGLVQVGGSLRLSCAASGYHFSSYVMSWVRQAPGKQREWVSAISGSGGSTYYADSVKGRFTISRDNSKNTLYLQMNSLRAEDTAVYYCAAAGTGVSDISEYYNPSLWQYWGQGSTVTVSS",
]

def main():
    sys.path.insert(0, os.path.join(NOVA, "external_tools", "boltzgen", "src"))
    from boltzgen.boltzgen_wrapper import BoltzgenWrapper

    subnet_config = {
        "nanobody_target": ["P05231"],
        "nanobody_target_clip_interval": [[27, 212]],
        "nanobody_structure": "4O9H",
        "nanobody_structure_chain": "A",
        "nanobody_structure_res_index": "21..186",
        "nanobody_structure_binding_site": "24,77,80,82,131,184..186",
    }
    valid = {6: {"sequences": CANDS}}
    w = BoltzgenWrapper()
    final_scores, comps = w.score_nanobodies(valid, subnet_config)
    print("=== PER-SEQUENCE METRICS ===")
    for seq, comp in comps.items():
        short = seq[:24] + "..."
        m = {k: (round(v, 4) if isinstance(v, (int, float)) else v) for k, v in comp.items() if k != "ranks"}
        print(short, json.dumps(m))
    print("=== FINAL RANK-SUM SCORES ===")
    print(json.dumps(final_scores, indent=1, default=str))


if __name__ == "__main__":
    main()
