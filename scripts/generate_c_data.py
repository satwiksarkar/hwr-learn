#!/usr/bin/env python3
"""
Generates driver/hwr_data.h containing embedded constant tables:
  - SEEDS (4369 x 9 bytes)
  - BASE_PROTOS (134 x 8 bytes)
  - ORIG_WEIGHTS (62 x 64 int8)
  - ORIG_BIASES (62 int16)
  - GRP & GRPMEM tables
Makes the C driver completely self-contained with zero runtime file dependencies.
"""

import os
import json
import numpy as np

DATA_DIR = os.path.join(os.path.dirname(__file__), "..", "hwr", "data")
OUTPUT_HEADER = os.path.join(os.path.dirname(__file__), "..", "driver", "hwr_data.h")


def generate():
    npz_path = os.path.join(DATA_DIR, "hwr_seeds_weights.npz")
    data = np.load(npz_path)
    seeds_grids = data["seeds_grids"]      # 4369, 8
    seeds_classes = data["seeds_classes"]  # 4369
    basep_grids = data["basep_grids"]      # 134, 7
    basep_classes = data["basep_classes"]  # 134
    weights = data["weights"]              # 62, 64
    biases = data["biases"]                # 62

    groups_path = os.path.join(DATA_DIR, "groups.json")
    with open(groups_path, "r") as f:
        grp_data = json.load(f)
    grp = grp_data["grp"]
    grpmem_raw = []
    for g in grp_data["grpmem"]:
        grpmem_raw.append(g["upper_code"])
        grpmem_raw.append(g["lower_code"])
        grpmem_raw.append(g["digit_code"])

    with open(OUTPUT_HEADER, "w") as f:
        f.write("/* Auto-generated HWR-LEARN constant data tables */\n")
        f.write("#ifndef HWR_DATA_H\n")
        f.write("#define HWR_DATA_H\n\n")
        f.write("#include <stdint.h>\n\n")

        # 1. GRP
        f.write("static const uint8_t HWR_GRP[128] = {\n    ")
        f.write(", ".join(str(x) for x in grp))
        f.write("\n};\n\n")

        # 2. GRPMEM
        f.write("static const uint8_t HWR_GRPMEM[42] = {\n    ")
        f.write(", ".join(str(x) for x in grpmem_raw))
        f.write("\n};\n\n")

        # 3. ORIG_WEIGHTS
        f.write(f"#define HWR_NUM_CLASSES 62\n")
        f.write(f"#define HWR_WEIGHTS_PER_CLASS 64\n")
        f.write("static const int8_t HWR_ORIG_WEIGHTS[62 * 64] = {\n    ")
        w_flat = weights.flatten().tolist()
        for i, val in enumerate(w_flat):
            f.write(f"{val}")
            if i < len(w_flat) - 1:
                f.write(", ")
                if (i + 1) % 16 == 0:
                    f.write("\n    ")
        f.write("\n};\n\n")

        # 4. ORIG_BIASES
        f.write("static const int16_t HWR_ORIG_BIASES[62] = {\n    ")
        b_flat = biases.flatten().tolist()
        f.write(", ".join(str(x) for x in b_flat))
        f.write("\n};\n\n")

        # 5. BASE_PROTOS (134 * 8)
        f.write("#define HWR_NUM_BASE_PROTOS 134\n")
        f.write("static const uint8_t HWR_BASE_PROTOS[134 * 8] = {\n    ")
        proto_bytes = []
        for g7, c in zip(basep_grids, basep_classes):
            proto_bytes.extend(g7.tolist())
            proto_bytes.append(int(c))
        for i, val in enumerate(proto_bytes):
            f.write(f"{val}")
            if i < len(proto_bytes) - 1:
                f.write(", ")
                if (i + 1) % 16 == 0:
                    f.write("\n    ")
        f.write("\n};\n\n")

        # 6. SEEDS (4369 * 9)
        f.write("#define HWR_NUM_SEEDS 4369\n")
        f.write("static const uint8_t HWR_SEEDS[4369 * 9] = {\n    ")
        seed_bytes = []
        for g8, c in zip(seeds_grids, seeds_classes):
            seed_bytes.extend(g8.tolist())
            seed_bytes.append(int(c))
        for i, val in enumerate(seed_bytes):
            f.write(f"{val}")
            if i < len(seed_bytes) - 1:
                f.write(", ")
                if (i + 1) % 18 == 0:
                    f.write("\n    ")
        f.write("\n};\n\n")

        f.write("#endif /* HWR_DATA_H */\n")

    print(f"Generated {OUTPUT_HEADER} successfully!")


if __name__ == "__main__":
    generate()
