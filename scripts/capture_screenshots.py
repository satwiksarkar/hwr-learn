"""
Captures high-resolution screenshots of HWR-LEARN in light & dark themes,
including drawing canvas with strokes, recognized text pills, and Top-3 popover.
"""

import os
import sys

# Add project root to sys.path
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Force offscreen QPA for headless environment
os.environ["QT_QPA_PLATFORM"] = "offscreen"

from PySide6.QtCore import Qt, QPoint
from PySide6.QtWidgets import QApplication
from PySide6.QtGui import QColor

from hwr.ui.main_window import MainWindow
from hwr.core.stroke import Stroke, Point
from hwr.ui.theme import LIGHT_THEME, DARK_THEME


def capture():
    app = QApplication.instance() or QApplication(sys.argv)
    
    out_dir = os.path.join(os.path.dirname(os.path.dirname(__file__)), "screenshots")
    os.makedirs(out_dir, exist_ok=True)
    
    win = MainWindow(db_path=":memory:")
    win.resize(1100, 720)
    win.show()
    app.processEvents()

    # Draw mock handwriting on the canvas: "Hey"
    # Stroke 1: H left bar
    s1 = Stroke([Point(80, 100), Point(80, 150), Point(80, 200)])
    # Stroke 2: H right bar
    s2 = Stroke([Point(130, 100), Point(130, 150), Point(130, 200)])
    # Stroke 3: H cross bar
    s3 = Stroke([Point(80, 150), Point(105, 150), Point(130, 150)])
    # Stroke 4: e loop
    s4 = Stroke([Point(160, 160), Point(180, 150), Point(160, 140), Point(150, 160), Point(175, 170)])
    # Stroke 5: y left
    s5 = Stroke([Point(200, 140), Point(215, 170)])
    # Stroke 6: y right and tail
    s6 = Stroke([Point(230, 140), Point(215, 170), Point(200, 210)])

    win.canvas.strokes = [s1.points, s2.points, s3.points, s4.points, s5.points, s6.points]
    win.canvas.update()
    app.processEvents()

    # Run recognition
    win.trigger_read()
    app.processEvents()

    # 1. Capture Light Theme
    win.apply_theme(LIGHT_THEME)
    app.processEvents()
    pix_light = win.grab()
    pix_light.save(os.path.join(out_dir, "hwr_light_100.png"))
    print(f"Saved {os.path.join(out_dir, 'hwr_light_100.png')}")

    # 2. Capture Dark Theme
    win.apply_theme(DARK_THEME)
    app.processEvents()
    pix_dark = win.grab()
    pix_dark.save(os.path.join(out_dir, "hwr_dark_100.png"))
    print(f"Saved {os.path.join(out_dir, 'hwr_dark_100.png')}")

    # 3. Capture with Teach drawer open
    win.teach_panel.setVisible(True)
    app.processEvents()
    pix_drawer = win.grab()
    pix_drawer.save(os.path.join(out_dir, "hwr_teach_drawer.png"))
    print(f"Saved {os.path.join(out_dir, 'hwr_teach_drawer.png')}")

    win.close()
    print("Screenshot capture complete!")


if __name__ == "__main__":
    capture()
