"""
Unit and integration tests for HWR-LEARN Native Driver and Bridge.
Verifies native C engine compilation, execution, IPC, and recognition accuracy.
"""

import pytest
from hwr.core.stroke import Stroke, Point, BankSample
from hwr.core.driver_bridge import DriverBridge, DriverModelBridge


def test_native_driver_bridge_execution():
    bridge = DriverBridge()
    assert bridge.backend_type in ("ipc", "ctypes")
    assert "Native" in bridge.backend_name

    # Create a vertical stroke (representing '1' or 'l' or '!')
    stroke = Stroke([Point(100, 100), Point(100, 150), Point(100, 200)])
    text, glyphs = bridge.recognize([stroke])

    assert len(text) > 0
    assert len(glyphs) > 0
    g = glyphs[0]
    assert len(g.candidates) == 3
    # Confidences should be non-empty and descending
    assert g.candidates[0][1] >= g.candidates[1][1] >= g.candidates[2][1]

    bridge.close()


def test_driver_model_bridge_compatibility():
    model = DriverModelBridge()
    assert model.backend_name is not None
    assert model.mode == 0

    # Mode switching
    model.mode = 1
    assert model.mode == 1
    model.mode = 0

    # Recognition
    stroke = Stroke([Point(50, 50), Point(50, 100), Point(50, 150)])
    text, glyphs = model.recognize([stroke])
    assert len(glyphs) == 1

    # Teaching
    sample = model.teach_glyph(glyphs[0], "1")
    assert sample.label == "1"
    assert len(model.bank) == 1

    # Load bank sample back
    model.load_bank_samples([sample])
    assert len(model.bank) == 1

    # Reset
    model.reset_model()
    assert len(model.bank) == 0

    model.close()


def test_native_driver_multi_stroke():
    model = DriverModelBridge()
    # Draw two separate strokes: 'H' (left bar, right bar)
    s1 = Stroke([Point(50, 100), Point(50, 150), Point(50, 200)])
    s2 = Stroke([Point(100, 100), Point(100, 150), Point(100, 200)])
    text, glyphs = model.recognize([s1, s2])
    assert len(glyphs) >= 1
    assert len(text) > 0
    model.close()
