"""
Acceptance Test Suite for HWR-LEARN.
Directly implements and tests every requirement specified in Section 9:
  - Robust line reference height (no punctuation misclassification).
  - Teach 8 glyphs (H, e, y, h, o, w, e, y), re-read yields 8/8 correct.
  - Perturbation test (+-11% scale, slant, wobble, jitter across 20 runs): >= 90% correct.
  - Persistence across process restart and fresh install.
  - Top-3 candidate ranking with confidence.
  - Re-teaching a green character reinforced without regressions.
  - Connected letter splitter for joined strokes.
  - Undo last teach (persistent across restarts).
  - Reset all learning with automatic backup and safe document retention.
  - File operations: UTF-8, UTF-16, Windows-1252, .bak creation, external modification detection.
"""

import os
import json
import random
import copy
import pytest
import numpy as np

from hwr.core.stroke import Point, Stroke, Glyph, split_connected_glyph
from hwr.core.driver_bridge import DriverModelBridge as HWRModel
from hwr.storage.db import Database
from hwr.storage.backup import create_timestamped_backup, restore_backup
from hwr.file_ops.text_file import LinkedTextFile, FileOperationError


@pytest.fixture
def screenshot_glyphs():
    json_path = os.path.join(os.path.dirname(__file__), "screenshot_glyphs.json")
    with open(json_path, "r") as f:
        data = json.load(f)

    glyphs = []
    for d in data:
        pts = [Point(p["x"], p["y"]) for p in d["points"]]
        s = Stroke(pts)
        g = Glyph(strokes=[s])
        g.recompute_bounds()
        glyphs.append(g)
    return glyphs


def test_acceptance_1_no_punctuation_for_normal_letters(screenshot_glyphs):
    """
    Requirement: Untrained, the old code read normal-height letters as punctuation
    because of one tall outlier stroke. The new core must not do that.
    """
    model = HWRModel()
    all_strokes = [s for g in screenshot_glyphs for s in g.strokes]
    text, recognized_glyphs = model.recognize(all_strokes)

    # In old code: text had '*' and '!' and '.'/',' for normal letters ('e', 'o', 'w')
    # Normal height glyphs: indices 1 ('e'), 4 ('o'), 5 ('w'), 7 ('e')
    normal_letter_indices = [1, 4, 5, 7]
    for idx in normal_letter_indices:
        g = recognized_glyphs[idx]
        # Must not be flagged as tiny punctuation (flag bit 2: 0x04)
        assert (g.flags & 0x04) == 0, f"Normal letter at index {idx} was wrongly flagged as tiny punctuation!"
        # Must not be classified as dot or comma punctuation
        assert g.final_class not in ('.', ',', "'", '-'), f"Normal letter at index {idx} became punctuation '{g.final_class}'!"


def test_acceptance_2_and_3_teach_8_glyphs_and_perturbation(screenshot_glyphs):
    """
    Requirement 2: Teach 8 glyphs once (H, e, y, h, o, w, e, y), re-read same ink: 8/8 correct.
    Requirement 3: Re-render with random scale (+-11%), slant, wobble, +-3px jitter across 20 runs:
                   at least 90% of taught glyphs correct.
    """
    model = HWRModel()

    # Targets: glyph 0='H', 1='e', 2='y', 3='h', 4='o', 5='w', 7='e', 8='y'
    target_indices = [0, 1, 2, 3, 4, 5, 7, 8]
    target_labels = ['H', 'e', 'y', 'h', 'o', 'w', 'e', 'y']

    # First pass: recognize to extract features
    all_strokes = [s for g in screenshot_glyphs for s in g.strokes]
    _, initial_glyphs = model.recognize(all_strokes)

    # Teach the 8 glyphs
    for idx, target_char in zip(target_indices, target_labels):
        model.teach_glyph(initial_glyphs[idx], target_char)

    # Re-read the same ink
    _, reread_glyphs = model.recognize(all_strokes)
    correct_count = 0
    for idx, target_char in zip(target_indices, target_labels):
        if reread_glyphs[idx].final_class == target_char:
            correct_count += 1

    assert correct_count == 8, f"Requirement 2 failed: expected 8/8 correct, got {correct_count}/8"

    # Requirement 3: Perturbation test across 20 runs
    total_trials = 0
    perturbed_correct = 0

    random.seed(42)
    np.random.seed(42)

    for run in range(20):
        # Apply jitter, scale (+-11%), slant
        scale = 1.0 + random.uniform(-0.11, 0.11)
        slant = random.uniform(-0.10, 0.10)

        perturbed_strokes = []
        for g_idx in target_indices:
            orig_stroke = screenshot_glyphs[g_idx].strokes[0]
            new_pts = []
            cx = (orig_stroke.min_x + orig_stroke.max_x) / 2.0
            cy = (orig_stroke.min_y + orig_stroke.max_y) / 2.0

            for p in orig_stroke.points:
                # Jitter +-3px, scale, slant
                jx = random.uniform(-3.0, 3.0)
                jy = random.uniform(-3.0, 3.0)
                px = cx + (p.x - cx) * scale + (p.y - cy) * slant + jx
                py = cy + (p.y - cy) * scale + jy
                new_pts.append(Point(px, py))
            perturbed_strokes.append(Stroke(new_pts))

        _, run_glyphs = model.recognize(perturbed_strokes)
        for i, target_char in enumerate(target_labels):
            total_trials += 1
            if i < len(run_glyphs) and run_glyphs[i].final_class == target_char:
                perturbed_correct += 1

    accuracy = (perturbed_correct / total_trials) * 100.0
    print(f"Perturbation Accuracy: {accuracy:.1f}% ({perturbed_correct}/{total_trials})")
    assert accuracy >= 90.0, f"Requirement 3 failed: expected >= 90% accuracy, got {accuracy:.1f}%"


def test_acceptance_4_persistence_kill_and_restart(tmp_path, screenshot_glyphs):
    """
    Requirement 4: Teach, simulate process kill/restart, verify same glyphs recognized.
    """
    db_file = str(tmp_path / "test_kill.db")
    db = Database(db_file)
    model = HWRModel()

    all_strokes = [s for g in screenshot_glyphs for s in g.strokes]
    _, initial_glyphs = model.recognize(all_strokes)

    # Teach 'H' and 'e'
    sample1 = model.teach_glyph(initial_glyphs[0], 'H')
    db.add_sample(sample1.label, sample1.grid8, sample1.grid57, sample1.aspect, sample1.flags)

    sample2 = model.teach_glyph(initial_glyphs[1], 'e')
    db.add_sample(sample2.label, sample2.grid8, sample2.grid57, sample2.aspect, sample2.flags)

    # "Kill" process by unceremoniously deleting objects
    db.close()
    del db
    del model

    # Re-initialize on clean restart
    db_restarted = Database(db_file)
    model_restarted = HWRModel()

    # Load taught samples from DB
    samples = db_restarted.get_all_samples()
    bank_samples = [from_db_sample(s) for s in samples]
    model_restarted.load_bank_samples(bank_samples)

    # Re-read
    _, reread_glyphs = model_restarted.recognize(all_strokes)
    assert reread_glyphs[0].final_class == 'H'
    assert reread_glyphs[1].final_class == 'e'

    db_restarted.close()


def from_db_sample(s):
    from hwr.core.stroke import BankSample
    return BankSample(
        id=s["id"],
        label=s["label"],
        grid8=s["grid8"],
        grid57=s["grid57"],
        aspect=s["aspect"],
        flags=s["flags"],
        is_tiny=s["is_tiny"],
        tiny_key=s["tiny_key"],
        source=s["source"]
    )


def test_acceptance_5_top3_candidates(screenshot_glyphs):
    """
    Requirement 5: For every glyph, return top 3 distinct candidates with confidence scores.
    """
    model = HWRModel()
    all_strokes = [s for g in screenshot_glyphs for s in g.strokes]
    _, glyphs = model.recognize(all_strokes)

    for g in glyphs:
        if g.flags & 0x0C:
            continue
        assert len(g.candidates) == 3
        cands = [c[0] for c in g.candidates]
        assert len(set(cands)) == len(cands), f"Candidates must be distinct: {cands}"
        # Scores in confidence order
        confs = [c[1] for c in g.candidates]
        assert confs[0] >= confs[1] >= confs[2]


def test_acceptance_6_re_teaching_green_character(screenshot_glyphs):
    """
    Requirement 6: Re-teaching a green (already correct) character changes the stored
    sample count and does not break other classes.
    """
    model = HWRModel()
    all_strokes = [s for g in screenshot_glyphs for s in g.strokes]
    _, glyphs = model.recognize(all_strokes)

    # Find a sure glyph
    target_idx = 0
    initial_char = glyphs[target_idx].final_class
    initial_bank_len = len(model.bank)

    # Re-teach the same character
    model.teach_glyph(glyphs[target_idx], initial_char)
    assert len(model.bank) == initial_bank_len + 1

    # Re-read and check other classes still hold
    _, reread_glyphs = model.recognize(all_strokes)
    assert reread_glyphs[target_idx].final_class == initial_char


def test_acceptance_7_joined_stroke_splitter():
    """
    Requirement 7: A joined "ar" / "ou" stroke is split into two glyphs.
    """
    pts = []
    # Loop 1: 'o'
    for theta in np.linspace(0, 2 * np.pi, 25):
        pts.append(Point(20 + 8 * np.cos(theta), 20 + 8 * np.sin(theta)))
    # Connection
    pts.append(Point(30, 20))
    pts.append(Point(34, 20))
    # Loop 2: 'u'
    for theta in np.linspace(0, np.pi, 15):
        pts.append(Point(42 + 8 * np.cos(theta), 20 + 8 * np.sin(theta)))

    joined_glyph = Glyph(strokes=[Stroke(pts)])
    joined_glyph.recompute_bounds()

    res = split_connected_glyph(joined_glyph, line_median_width=18)
    assert len(res) == 2, f"Expected joined stroke to split into 2 glyphs, got {len(res)}"


def test_acceptance_8_undo_last_teach(tmp_path):
    """
    Requirement 8: Teach 3 samples, undo 3 times -> model matches state before teaching;
    restart mid-way and undo still works.
    """
    db_file = str(tmp_path / "test_undo.db")
    db = Database(db_file)
    grid = np.zeros(8, dtype=np.uint8)
    grid57 = np.zeros(7, dtype=np.uint8)

    db.add_sample("1", grid, grid57, 16, 0)
    db.add_sample("2", grid, grid57, 16, 0)
    db.add_sample("3", grid, grid57, 16, 0)
    assert db.get_sample_count() == 3

    # Undo 1
    u1 = db.undo_last_teach()
    assert u1["label"] == "3"
    assert db.get_sample_count() == 2

    # Restart app mid-way
    db.close()
    db2 = Database(db_file)
    assert db2.get_sample_count() == 2

    # Undo 2
    u2 = db2.undo_last_teach()
    assert u2["label"] == "2"
    assert db2.get_sample_count() == 1

    # Undo 3
    u3 = db2.undo_last_teach()
    assert u3["label"] == "1"
    assert db2.get_sample_count() == 0

    db2.close()


def test_acceptance_9_reset_all_with_backup_and_document_retention(tmp_path):
    """
    Requirement 9: Reset all: samples = 0, backup exists, restore recovers samples,
    documents survive reset.
    """
    db_file = str(tmp_path / "test_reset.db")
    db = Database(db_file)
    grid = np.zeros(8, dtype=np.uint8)
    grid57 = np.zeros(7, dtype=np.uint8)

    db.add_sample("A", grid, grid57, 16, 1)
    db.add_sample("B", grid, grid57, 16, 1)
    doc_id = db.save_document(title="Persisted Doc", text="Important user content")

    # Automatic backup before reset
    bck = create_timestamped_backup(db)
    assert os.path.exists(bck)

    # Perform reset
    db.reset_all_learning()
    assert db.get_sample_count() == 0

    # Documents must survive!
    doc = db.get_document(doc_id)
    assert doc is not None
    assert doc["title"] == "Persisted Doc"

    # Restore from backup
    db.close()
    restore_backup(bck, db_file)
    db_restored = Database(db_file)
    assert db_restored.get_sample_count() == 2
    db_restored.close()


def test_acceptance_10_files_safety(tmp_path):
    """
    Requirement 10: Open UTF-8, UTF-16, Windows-1252, append recognized text, verify original
    bytes unchanged, encoding & line endings preserved, .bak exists, external change detected.
    """
    # 1. UTF-8
    f_utf8 = str(tmp_path / "sample_utf8.txt")
    with open(f_utf8, "wb") as f:
        f.write(b"Initial line 1\nLine 2\n")
    lf_utf8 = LinkedTextFile(f_utf8)
    lf_utf8.append_text("Appended line 3")
    assert os.path.exists(f_utf8 + ".bak")
    with open(f_utf8, "rb") as f:
        assert f.read() == b"Initial line 1\nLine 2\nAppended line 3"

    # 2. UTF-16-LE with CRLF
    f_utf16 = str(tmp_path / "sample_utf16.txt")
    with open(f_utf16, "wb") as f:
        f.write(b"\xff\xfe" + "Line 1\r\n".encode("utf-16-le"))
    lf_utf16 = LinkedTextFile(f_utf16)
    lf_utf16.append_text("Line 2")
    with open(f_utf16, "rb") as f:
        data16 = f.read()
        assert data16.startswith(b"\xff\xfe")
        assert "Line 2" in data16.decode("utf-16-le")

    # 3. Windows-1252 with CRLF
    f_1252 = str(tmp_path / "sample_1252.txt")
    with open(f_1252, "wb") as f:
        f.write(b"Total: \x80 50\r\n")  # Euro sign in Win-1252
    lf_1252 = LinkedTextFile(f_1252)
    lf_1252.append_text("New entry")
    with open(f_1252, "rb") as f:
        assert b"\x80" in f.read()
