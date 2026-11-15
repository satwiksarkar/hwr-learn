"""
Backup, restore, and model export/import operations for HWR-LEARN.
Completely zero-numpy implementation using standard Python bytes and SQLite.
"""

import os
import shutil
import sqlite3
import datetime
import json
import struct
from typing import List, Dict, Any, Optional

from .db import Database


def get_backup_dir(db_path: str) -> str:
    backup_dir = os.path.join(os.path.dirname(db_path), "backups")
    os.makedirs(backup_dir, exist_ok=True)
    return backup_dir


def create_timestamped_backup(db: Database, max_rolling: int = 5) -> str:
    """
    Creates an atomic rolling backup of the database using SQLite's online backup API.
    Maintains at most `max_rolling` (default 5) backups.
    """
    backup_dir = get_backup_dir(db.db_path)
    now_str = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    backup_filename = f"hwrlearn_backup_{now_str}.db"
    backup_path = os.path.join(backup_dir, backup_filename)

    # Use SQLite online backup API to ensure safety even during WAL writes
    bck_conn = sqlite3.connect(backup_path)
    with bck_conn:
        db.conn.backup(bck_conn)
    bck_conn.close()

    # Prune old backups to keep at most max_rolling
    existing = list_backups(db.db_path)
    if len(existing) > max_rolling:
        for old in existing[max_rolling:]:
            try:
                os.remove(old["path"])
            except OSError:
                pass

    return backup_path


def list_backups(db_path: str) -> List[Dict[str, Any]]:
    backup_dir = get_backup_dir(db_path)
    if not os.path.exists(backup_dir):
        return []

    files = [f for f in os.listdir(backup_dir) if f.startswith("hwrlearn_backup_") and f.endswith(".db")]
    results = []
    for f in files:
        full_path = os.path.join(backup_dir, f)
        stat = os.stat(full_path)
        results.append({
            "filename": f,
            "path": full_path,
            "size": stat.st_size,
            "modified": datetime.datetime.fromtimestamp(stat.st_mtime).isoformat()
        })
    results.sort(key=lambda x: x["filename"], reverse=True)
    return results


def restore_backup(backup_path: str, target_db_path: str):
    """Restores database contents from an existing backup file."""
    if not os.path.exists(backup_path):
        raise FileNotFoundError(f"Backup file not found at {backup_path}")

    src_conn = sqlite3.connect(backup_path)
    dest_conn = sqlite3.connect(target_db_path)
    with dest_conn:
        src_conn.backup(dest_conn)
    src_conn.close()
    dest_conn.close()


def export_model_json(db: Database, export_path: str):
    """Exports learned samples as a portable JSON file."""
    samples = db.get_all_samples()
    export_data = {
        "format": "HWR-LEARN-MODEL-V1",
        "exported_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "sample_count": len(samples),
        "samples": []
    }
    for s in samples:
        export_data["samples"].append({
            "label": s["label"],
            "grid8": [int(x) for x in s["grid8"]],
            "grid57": [int(x) for x in s["grid57"]],
            "aspect": s["aspect"],
            "flags": s["flags"],
            "is_tiny": s["is_tiny"],
            "tiny_key": s["tiny_key"]
        })

    with open(export_path, "w", encoding="utf-8") as f:
        json.dump(export_data, f, indent=2)


def import_model_json(db: Database, import_path: str) -> int:
    """Imports samples from a JSON model file into the database."""
    with open(import_path, "r", encoding="utf-8") as f:
        data = json.load(f)

    if data.get("format") != "HWR-LEARN-MODEL-V1":
        raise ValueError("Unrecognized model file format.")

    samples = data.get("samples", [])
    count = 0
    for s in samples:
        grid8 = bytes(s["grid8"])
        grid57 = bytes(s["grid57"])
        db.add_sample(
            label=s["label"],
            grid8=grid8,
            grid57=grid57,
            aspect=s["aspect"],
            flags=s["flags"],
            is_tiny=s.get("is_tiny", False),
            tiny_key=s.get("tiny_key", 0),
            source="imported"
        )
        count += 1
    return count


def load_legacy_learn_dat(data: bytes) -> Dict[str, Any]:
    """Parses a legacy LEARN.DAT binary buffer from DOSBox without numpy."""
    MAGIC = b"HWR3"
    HEADER_FORMAT = "<4shhhhHHHH"
    if len(data) < 18 + 4092 + 2:
        raise ValueError(f"LEARN.DAT too small ({len(data)} bytes, expected at least 4112)")

    if data[:4] != MAGIC:
        raise ValueError(f"Invalid magic: expected {MAGIC}, got {data[:4]}")

    magic, yoff, case_t, abs_t, nbank, nlprot, banknxt, lpnxt = struct.unpack_from(HEADER_FORMAT, data, 0)
    expected_payload = 18 + (nbank * 18) + (nlprot * 8) + (62 * 64) + 124
    if len(data) < expected_payload + 2:
        raise ValueError(f"Truncated LEARN.DAT")

    checksum = sum(data[:expected_payload]) & 0xFFFF
    file_checksum = struct.unpack_from("<H", data, expected_payload)[0]
    if checksum != file_checksum:
        raise ValueError(f"Checksum mismatch: calculated {checksum}, file has {file_checksum}")

    offset = 18
    bank_samples = []
    for _ in range(nbank):
        grid8 = bytes(data[offset:offset + 8])
        grid57 = bytes(data[offset + 8:offset + 15])
        label_byte = data[offset + 15]
        flag_byte = data[offset + 16]
        aspect_byte = data[offset + 17]
        label = chr(label_byte)
        bank_samples.append({
            "grid8": grid8,
            "grid57": grid57,
            "label": label,
            "flags": flag_byte,
            "aspect": aspect_byte,
            "is_tiny": (flag_byte & 0x04) != 0,
            "tiny_key": grid8[0] if (flag_byte & 0x04) else 0,
            "source": "dosbox_dat"
        })
        offset += 18

    return {"bank_samples": bank_samples}
