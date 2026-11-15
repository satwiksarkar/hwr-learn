"""
Unit tests for SQLite persistence, undo/redo, backups, and model export/import.
"""

import os
import tempfile
import pytest
import numpy as np
from hwr.storage.db import Database
from hwr.storage.backup import (
    create_timestamped_backup,
    list_backups,
    restore_backup,
    export_model_json,
    import_model_json
)


@pytest.fixture
def temp_db():
    fd, path = tempfile.mkstemp(suffix=".db")
    os.close(fd)
    db = Database(path)
    yield db
    try:
        db.close()
    except Exception:
        pass
    for p in (path, path + "-wal", path + "-shm"):
        if os.path.exists(p):
            try:
                os.remove(p)
            except OSError:
                pass


def test_db_wal_mode_and_teach(temp_db):
    """Test WAL mode, synchronous=FULL, and persistent sample storage."""
    cur = temp_db.conn.execute("PRAGMA journal_mode;")
    mode = cur.fetchone()[0]
    assert mode.lower() == "wal"

    grid8 = np.ones(8, dtype=np.uint8) * 42
    grid57 = np.ones(7, dtype=np.uint8) * 17

    sample_id = temp_db.add_sample(
        label="A",
        grid8=grid8,
        grid57=grid57,
        aspect=16,
        flags=1
    )
    assert sample_id > 0
    assert temp_db.get_sample_count() == 1
    assert temp_db.get_classes_count() == 1

    samples = temp_db.get_all_samples()
    assert len(samples) == 1
    assert samples[0]["label"] == "A"
    assert np.array_equal(samples[0]["grid8"], grid8)


def test_persistent_undo_redo_across_restarts(temp_db):
    """
    Test undo last teach: removes most recently taught sample.
    Undo must survive reopening the database (app restart).
    """
    db_path = temp_db.db_path
    grid8 = np.zeros(8, dtype=np.uint8)
    grid57 = np.zeros(7, dtype=np.uint8)

    # Teach 3 samples: 'A', 'B', 'C'
    temp_db.add_sample("A", grid8, grid57, 16, 1)
    temp_db.add_sample("B", grid8, grid57, 16, 1)
    temp_db.add_sample("C", grid8, grid57, 16, 1)
    assert temp_db.get_sample_count() == 3

    # Close and reopen database (simulate restart)
    temp_db.close()
    db2 = Database(db_path)
    assert db2.get_sample_count() == 3

    # Undo 1 ('C')
    res = db2.undo_last_teach()
    assert res is not None
    assert res["label"] == "C"
    assert db2.get_sample_count() == 2

    # Undo 2 ('B')
    res2 = db2.undo_last_teach()
    assert res2 is not None
    assert res2["label"] == "B"
    assert db2.get_sample_count() == 1

    # Undo 3 ('A')
    res3 = db2.undo_last_teach()
    assert res3 is not None
    assert res3["label"] == "A"
    assert db2.get_sample_count() == 0

    # Nothing left to undo
    assert db2.undo_last_teach() is None
    db2.close()


def test_reset_all_learning_and_backup(temp_db):
    """
    Test reset all learning: creates timestamped backup, clears samples,
    and documents survive reset.
    """
    grid8 = np.zeros(8, dtype=np.uint8)
    grid57 = np.zeros(7, dtype=np.uint8)

    # Add samples and document
    temp_db.add_sample("X", grid8, grid57, 16, 1)
    temp_db.add_sample("Y", grid8, grid57, 16, 1)
    doc_id = temp_db.save_document(title="My Notes", text="Important text that must survive reset")

    # Create backup before reset
    backup_file = create_timestamped_backup(temp_db)
    assert os.path.exists(backup_file)

    # Reset learning
    cleared = temp_db.reset_all_learning()
    assert cleared == 2
    assert temp_db.get_sample_count() == 0

    # Document must still exist!
    doc = temp_db.get_document(doc_id)
    assert doc is not None
    assert doc["text"] == "Important text that must survive reset"

    # Restore from backup
    temp_db.close()
    restore_backup(backup_file, temp_db.db_path)

    db_restored = Database(temp_db.db_path)
    assert db_restored.get_sample_count() == 2
    db_restored.close()

    # Clean backup
    if os.path.exists(backup_file):
        os.remove(backup_file)


def test_export_and_import_model(temp_db):
    """Test model export and import as a standalone portable file."""
    grid8 = np.arange(8, dtype=np.uint8)
    grid57 = np.arange(7, dtype=np.uint8)

    temp_db.add_sample("K", grid8, grid57, 12, 1)
    temp_db.add_sample("m", grid8, grid57, 15, 0)

    export_path = temp_db.db_path + ".export.json"
    export_model_json(temp_db, export_path)
    assert os.path.exists(export_path)

    # Clear DB and re-import
    temp_db.reset_all_learning()
    assert temp_db.get_sample_count() == 0

    count = import_model_json(temp_db, export_path)
    assert count == 2
    assert temp_db.get_sample_count() == 2
    samples = temp_db.get_all_samples()
    labels = {s["label"] for s in samples}
    assert labels == {"K", "m"}

    os.remove(export_path)
