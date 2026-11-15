"""
Teach Mode panel for inspecting, practicing, and managing taught samples.
Includes sample thumbnail preview, delete individual sample, and two-step reset.
"""

from typing import Dict, Any, List, Optional
import numpy as np
from PySide6.QtCore import Qt, Signal
from PySide6.QtGui import QPainter, QColor, QImage, QPixmap
from PySide6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel, QComboBox,
    QPushButton, QScrollArea, QFrame, QMessageBox, QInputDialog
)

from ..storage.db import Database


class ThumbnailWidget(QFrame):
    deleteRequested = Signal(int)

    def __init__(self, sample: Dict[str, Any], theme: Dict[str, Any], parent=None):
        super().__init__(parent)
        self.sample_id = sample["id"]
        self.setFixedSize(90, 110)
        self.setStyleSheet(f"""
            QFrame {{
                background-color: {theme['bg_card']};
                border: 1px solid {theme['border_subtle']};
                border-radius: 8px;
            }}
            QFrame:hover {{
                border-color: {theme['accent']};
            }}
        """)

        layout = QVBoxLayout(self)
        layout.setContentsMargins(6, 6, 6, 6)
        layout.setSpacing(4)

        # 8x8 Skeleton preview
        img_label = QLabel(self)
        img_label.setFixedSize(64, 64)
        img_label.setAlignment(Qt.AlignCenter)
        img_label.setPixmap(self._render_grid_pixmap(sample["grid8"], theme))
        layout.addWidget(img_label, alignment=Qt.AlignCenter)

        # Timestamp or label
        info = QLabel(f"'{sample['label']}'", self)
        info.setStyleSheet(f"color: {theme['text_secondary']}; font-size: 11px; font-weight: 600;")
        info.setAlignment(Qt.AlignCenter)
        layout.addWidget(info)

        # Delete button
        del_btn = QPushButton("✕", self)
        del_btn.setFixedSize(18, 18)
        del_btn.setCursor(Qt.PointingHandCursor)
        del_btn.setStyleSheet(f"""
            background-color: transparent;
            color: {theme['unsure']};
            border: none;
            font-size: 10px;
            font-weight: bold;
        """)
        del_btn.clicked.connect(lambda: self.deleteRequested.emit(self.sample_id))
        del_btn.setParent(self)
        del_btn.move(70, 2)

    def _render_grid_pixmap(self, grid8: np.ndarray, theme: Dict[str, Any]) -> QPixmap:
        img = QImage(8, 8, QImage.Format_RGB32)
        bg = QColor(theme["bg_app"]).rgb()
        fg = QColor(theme["accent"]).rgb()
        img.fill(bg)

        for r in range(8):
            v = int(grid8[r])
            for c in range(8):
                if v & (1 << (7 - c)):
                    img.setPixel(c, r, fg)

        pixmap = QPixmap.fromImage(img)
        return pixmap.scaled(60, 60, Qt.KeepAspectRatio, Qt.FastTransformation)


class TeachPanel(QWidget):
    sampleDeleted = Signal()
    allReset = Signal()

    def __init__(self, db: Database, parent=None):
        super().__init__(parent)
        self.db = db
        self.theme: Dict[str, Any] = {}

        self.setFixedWidth(320)
        self.main_layout = QVBoxLayout(self)
        self.main_layout.setContentsMargins(16, 16, 16, 16)
        self.main_layout.setSpacing(12)

        # Title
        header = QHBoxLayout()
        title = QLabel("Teach Mode", self)
        title.setStyleSheet("font-size: 15px; font-weight: 700;")
        header.addWidget(title)
        self.total_badge = QLabel("0 samples", self)
        self.total_badge.setStyleSheet("font-size: 11px; opacity: 0.7;")
        header.addWidget(self.total_badge)
        header.addStretch()
        self.main_layout.addLayout(header)

        # Class picker
        picker_box = QVBoxLayout()
        picker_box.setSpacing(4)
        lbl = QLabel("Filter by character class:", self)
        lbl.setStyleSheet("font-size: 12px; font-weight: 500;")
        picker_box.addWidget(lbl)

        self.class_combo = QComboBox(self)
        self.class_combo.currentIndexChanged.connect(self._on_class_changed)
        picker_box.addWidget(self.class_combo)
        self.main_layout.addLayout(picker_box)

        # Scroll area for thumbnails grid
        self.scroll_area = QScrollArea(self)
        self.scroll_area.setWidgetResizable(True)
        self.scroll_area.setFrameShape(QFrame.NoFrame)

        self.grid_container = QWidget()
        self.grid_layout = QVBoxLayout(self.grid_container)
        self.grid_layout.setContentsMargins(4, 4, 4, 4)
        self.grid_layout.setSpacing(8)
        self.scroll_area.setWidget(self.grid_container)
        self.main_layout.addWidget(self.scroll_area, stretch=1)

        # Danger zone: Reset All Learning
        danger_box = QVBoxLayout()
        danger_box.setSpacing(6)

        self.reset_char_btn = QPushButton("Reset This Character", self)
        self.reset_char_btn.clicked.connect(self._reset_character)
        danger_box.addWidget(self.reset_char_btn)

        self.reset_all_btn = QPushButton("Reset All Learning...", self)
        self.reset_all_btn.setObjectName("dangerButton")
        self.reset_all_btn.clicked.connect(self._reset_all_learning)
        danger_box.addWidget(self.reset_all_btn)

        self.main_layout.addLayout(danger_box)

    def set_theme(self, theme: Dict[str, Any]):
        self.theme = theme
        self.reload_samples()

    def reload_samples(self):
        samples = self.db.get_all_samples()
        total_count = len(samples)
        self.total_badge.setText(f"{total_count} taught samples")

        # Update classes in combo
        classes = sorted(list(set(s["label"] for s in samples)))
        curr_selected = self.class_combo.currentText()

        self.class_combo.blockSignals(True)
        self.class_combo.clear()
        self.class_combo.addItem("All Classes")
        for c in classes:
            c_samples = [s for s in samples if s["label"] == c]
            self.class_combo.addItem(f"'{c}' ({len(c_samples)} samples)", c)
        self.class_combo.blockSignals(False)

        self._render_thumbnails(samples)

    def _on_class_changed(self):
        samples = self.db.get_all_samples()
        data = self.class_combo.currentData()
        if data:
            samples = [s for s in samples if s["label"] == data]
        self._render_thumbnails(samples)

    def _render_thumbnails(self, samples: List[Dict[str, Any]]):
        while self.grid_layout.count():
            item = self.grid_layout.takeAt(0)
            widget = item.widget()
            layout = item.layout()
            if widget:
                widget.deleteLater()
            elif layout:
                while layout.count():
                    sub = layout.takeAt(0)
                    if sub.widget():
                        sub.widget().deleteLater()

        if not samples:
            lbl = QLabel("No samples taught yet.\nClick any character in the text view to teach it.", self)
            lbl.setStyleSheet(f"color: {self.theme.get('text_muted', '#888')}; font-size: 12px; padding: 20px 0;")
            lbl.setAlignment(Qt.AlignCenter)
            self.grid_layout.addWidget(lbl)
            return

        # Arrange in rows of 3
        row = None
        for i, s in enumerate(samples):
            if i % 3 == 0:
                row = QHBoxLayout()
                row.setSpacing(6)
                row.setAlignment(Qt.AlignLeft)
                self.grid_layout.addLayout(row)

            card = ThumbnailWidget(s, self.theme, self.grid_container)
            card.deleteRequested.connect(self._delete_sample)
            if row:
                row.addWidget(card)

        self.grid_layout.addStretch()

    def _delete_sample(self, sample_id: int):
        self.db.delete_sample(sample_id)
        self.reload_samples()
        self.sampleDeleted.emit()

    def _reset_character(self):
        curr_char = self.class_combo.currentData()
        if not curr_char:
            QMessageBox.information(self, "Select Character", "Please pick a specific character to reset.")
            return

        reply = QMessageBox.question(
            self,
            "Confirm Reset Character",
            f"Are you sure you want to delete all learned samples for character '{curr_char}'?",
            QMessageBox.Yes | QMessageBox.No
        )
        if reply == QMessageBox.Yes:
            self.db.reset_character_samples(curr_char)
            self.reload_samples()
            self.sampleDeleted.emit()

    def _reset_all_learning(self):
        """Two-step confirmation Reset All Learning."""
        count = self.db.get_sample_count()
        if count == 0:
            QMessageBox.information(self, "Empty", "No learned samples exist to reset.")
            return

        # Step 1
        msg = f"WARNING: This will permanently delete ALL {count} user-taught samples!\n\nAn automatic timestamped backup will be created.\nSaved documents will NOT be deleted.\n\nAre you sure?"
        reply = QMessageBox.warning(self, "Step 1: Reset All Learning", msg, QMessageBox.Yes | QMessageBox.No)
        if reply != QMessageBox.Yes:
            return

        # Step 2: Require typing RESET
        text, ok = QInputDialog.getText(
            self,
            "Step 2: Confirm Reset",
            "To confirm, type 'RESET' in capital letters below:"
        )
        if ok and text == "RESET":
            from ..storage.backup import create_timestamped_backup
            bck = create_timestamped_backup(self.db)
            self.db.reset_all_learning()
            self.reload_samples()
            self.allReset.emit()
            QMessageBox.information(
                self,
                "Reset Complete",
                f"All learning erased.\nA recovery backup was saved to:\n{bck}"
            )
        elif ok:
            QMessageBox.critical(self, "Cancelled", "Confirmation text did not match 'RESET'. Reset cancelled.")
