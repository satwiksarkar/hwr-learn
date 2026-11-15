#!/usr/bin/env python3
"""
Extractor script for HWR-LEARN assets from reference/hwr_learn_improved.asm.
Extracts:
  - 4369 8x8 font skeleton seeds (SEEDS)
  - 134 5x7 base prototypes (BASEP)
  - 62-class initial perceptron weights (ORIGW, 62x64) and biases (ORIGB, 62)
  - Character group definitions (GRP, GRPMEM)
Outputs both raw binary files and structured JSON/NPZ for fast offline loading.
"""

import os
import json
import numpy as np

ASM_PATH = os.path.join(os.path.dirname(__file__), "..", "reference", "hwr_learn_improved.asm")
OUTPUT_DIR = os.path.join(os.path.dirname(__file__), "..", "hwr", "data")


def parse_data_block(lines, start_line, end_line, is_word=False):
    items = []
    for line in lines[start_line:end_line]:
        c_idx = line.find(';')
        if c_idx >= 0:
            line = line[:c_idx]
        line = line.strip()
        if not line:
            continue
        parts = line.split(None, 1)
        if len(parts) < 2:
            continue
        directive, val_str = parts[0].lower(), parts[1]
        if directive not in ('db', 'dw'):
            continue
        for token in val_str.split(','):
            token = token.strip()
            if not token:
                continue
            if token.endswith('h') or token.endswith('H'):
                val = int(token[:-1], 16)
                if is_word and val >= 0x8000:
                    val -= 0x10000
                elif not is_word and val >= 0x80:
                    val -= 0x100
            else:
                val = int(token)
            items.append(val)
    return items


def extract():
    print(f"Reading {ASM_PATH}...")
    with open(ASM_PATH, "r", encoding="latin-1") as f:
        lines = f.readlines()

    os.makedirs(OUTPUT_DIR, exist_ok=True)

    # 1. GRP & GRPMEM
    grp = parse_data_block(lines, 267, 275)
    assert len(grp) == 128, f"Expected 128 GRP bytes, got {len(grp)}"

    grpmem_raw = parse_data_block(lines, 276, 291)
    assert len(grpmem_raw) == 42, f"Expected 42 GRPMEM bytes, got {len(grpmem_raw)}"
    grpmem = []
    for i in range(0, len(grpmem_raw), 3):
        grpmem.append({
            "upper": chr(grpmem_raw[i]) if grpmem_raw[i] != 0 else None,
            "lower": chr(grpmem_raw[i+1]) if grpmem_raw[i+1] != 0 else None,
            "digit": chr(grpmem_raw[i+2]) if grpmem_raw[i+2] != 0 else None,
            "upper_code": grpmem_raw[i],
            "lower_code": grpmem_raw[i+1],
            "digit_code": grpmem_raw[i+2],
        })

    groups_data = {
        "grp": grp,
        "grpmem": grpmem
    }
    with open(os.path.join(OUTPUT_DIR, "groups.json"), "w") as f:
        json.dump(groups_data, f, indent=2)

    # 2. ORIGW (62 classes x 64 inputs = 3968 INT8)
    origw_raw = parse_data_block(lines, 5201, 5263)
    assert len(origw_raw) == 3968, f"Expected 3968 weights, got {len(origw_raw)}"
    weights = np.array(origw_raw, dtype=np.int8).reshape((62, 64))

    # 3. ORIGB (62 INT16)
    origb_raw = parse_data_block(lines, 5264, 5268, is_word=True)
    assert len(origb_raw) == 62, f"Expected 62 biases, got {len(origb_raw)}"
    biases = np.array(origb_raw, dtype=np.int16)

    # 4. BASEP (134 prototypes x 8 bytes: 7 rows of 5-bit grid + 1 byte ASCII)
    basep_raw = parse_data_block(lines, 5269, 5403)
    assert len(basep_raw) == 134 * 8, f"Expected 1072 prototype bytes, got {len(basep_raw)}"
    proto_grids = []
    proto_classes = []
    for i in range(0, len(basep_raw), 8):
        proto_grids.append(basep_raw[i:i+7])
        proto_classes.append(basep_raw[i+7])

    basep_grids = np.array(proto_grids, dtype=np.uint8)  # 134 x 7
    basep_classes = np.array(proto_classes, dtype=np.uint8)  # 134

    # 5. SEEDS (4369 seeds x 9 bytes: 8 rows of 8-bit grid + 1 byte ASCII)
    seeds_raw = parse_data_block(lines, 5404, 9774)
    assert len(seeds_raw) == 4369 * 9, f"Expected 39321 seed bytes, got {len(seeds_raw)}"
    seed_grids = []
    seed_classes = []
    for i in range(0, len(seeds_raw), 9):
        seed_grids.append(seeds_raw[i:i+8])
        seed_classes.append(seeds_raw[i+8])

    seeds_grids = np.array(seed_grids, dtype=np.uint8)  # 4369 x 8
    seeds_classes = np.array(seed_classes, dtype=np.uint8)  # 4369

    # Save to NPZ package
    npz_path = os.path.join(OUTPUT_DIR, "hwr_seeds_weights.npz")
    np.savez_compressed(
        npz_path,
        weights=weights,
        biases=biases,
        basep_grids=basep_grids,
        basep_classes=basep_classes,
        seeds_grids=seeds_grids,
        seeds_classes=seeds_classes
    )
    print(f"Saved compressed model assets to {npz_path}")

    # Also save raw binaries for transparency / C / SQLite embedding
    with open(os.path.join(OUTPUT_DIR, "seeds.bin"), "wb") as f:
        f.write(bytes(seeds_raw))
    with open(os.path.join(OUTPUT_DIR, "prototypes.bin"), "wb") as f:
        f.write(bytes(basep_raw))
    with open(os.path.join(OUTPUT_DIR, "weights.bin"), "wb") as f:
        f.write(weights.tobytes())
    with open(os.path.join(OUTPUT_DIR, "biases.bin"), "wb") as f:
        f.write(biases.tobytes())

    metadata = {
        "seeds_count": 4369,
        "prototypes_count": 134,
        "perceptron_classes": 62,
        "default_case_t": 68,
        "default_abs_t": 42,
        "margin_x": 2,
        "margin_y": 16,
        "descender_threshold_percent": 12,  # Fix 4: changed from 22 to 12
        "bank_raw_override_dist": 14,       # Fix 2: bank override at <= 14
        "bank_scale_num": 5,                # Fix 2: 5/8 scaling
        "bank_scale_den": 8,
        "bank_trust_bonus": 3               # Fix 2: subtract 3
    }
    with open(os.path.join(OUTPUT_DIR, "metadata.json"), "w") as f:
        json.dump(metadata, f, indent=2)

    print("Asset extraction completed successfully!")


if __name__ == "__main__":
    extract()
