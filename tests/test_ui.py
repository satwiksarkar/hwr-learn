"""
UI offscreen tests for MainWindow, theme switching, canvas strokes, and popover.
"""

import os
import pytest
from PySide6.QtWidgets import QApplication

os.environ["QT_QPA_PLATFORM"] = "offscreen"


@pytest.fixture(scope="session")
def qapp():
    app = QApplication.instance()
    if app is None:
        app = QApplication([])
    return app


def test_main_window_offscreen(qapp, tmp_path):
    from hwr.ui.main_window import MainWindow
    from hwr.core.stroke import Point

    db_path = str(tmp_path / "ui_test.db")
    win = MainWindow(db_path=db_path)
    win.show()

    assert "HWR-LEARN" in win.windowTitle()

    # Simulate drawing a stroke
    win.canvas.strokes.append([Point(50, 100), Point(50, 150)])
    win.canvas.update()
    qapp.processEvents()

    # Test Theme toggle
    initial_theme = win.current_theme["name"]
    win.toggle_theme()
    assert win.current_theme["name"] != initial_theme
    win.toggle_theme()
    assert win.current_theme["name"] == initial_theme

    # Test Drawer toggles
    win._toggle_teach_drawer()
    assert win.teach_panel.isVisible()
    win._toggle_teach_drawer()
    assert not win.teach_panel.isVisible()

    win.close()
