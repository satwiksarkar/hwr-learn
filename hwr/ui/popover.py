"""
Anchored Top-3 Dropdown Popover Card for HWR-LEARN.
Displays top 3 candidates with confidence scores, custom character teaching input,
and glyph deletion.
"""

from typing import List, Tuple, Dict, Any, Optional
from PySide6.QtCore import Qt, Signal, QPoint
from PySide6.QtGui import QColor, QFont
from PySide6.QtWidgets import (
    QFrame, QVBoxLayout, QHBoxLayout, QLabel, QLineEdit,
    QPushButton, QProgressBar, QWidget
)


class CandidateRow(QWidget):
    clicked = Signal(str)

    def __init__(self, index: int, char: str, confidence: float, theme: Dict[str, Any], parent=None):
        super().__init__(parent)
        self.char = char
        self.setCursor(Qt.PointingHandCursor)

        layout = QHBoxLayout(self)
        layout.setContentsMargins(8, 6, 8, 6)
        layout.setSpacing(10)

        # Index label (1., 2., 3.)
        idx_label = QLabel(f"{index}.", self)
        idx_label.setStyleSheet(f"color: {theme['text_muted']}; font-family: monospace; font-size: 11px;")
        idx_label.setFixedWidth(16)
        layout.addWidget(idx_label)

        # Character glyph
        char_label = QLabel(char, self)
        char_label.setStyleSheet(f"color: {theme['text_primary']}; font-weight: 600; font-size: 18px; font-family: monospace;")
        char_label.setFixedWidth(24)
        layout.addWidget(char_label)

        # Mini confidence progress bar
        self.bar = QProgressBar(self)
        self.bar.setRange(0, 100)
        self.bar.setValue(int(confidence))
        self.bar.setTextVisible(False)
        self.bar.setFixedHeight(6)
        self.bar.setStyleSheet(f"""
            QProgressBar {{
                background-color: {theme['border_subtle']};
                border-radius: 3px;
                border: none;
            }}
            QProgressBar::chunk {{
                background-color: {theme['accent']};
                border-radius: 3px;
            }}
        """)
        layout.addWidget(self.bar, stretch=1)

        # Percentage label
        conf_label = QLabel(f"{confidence:.0f}%", self)
        conf_label.setStyleSheet(f"color: {theme['text_secondary']}; font-size: 11px; font-family: monospace;")
        conf_label.setFixedWidth(34)
        conf_label.setAlignment(Qt.AlignRight | Qt.AlignVCenter)
        layout.addWidget(conf_label)

        self.setStyleSheet(f"""
            QWidget:hover {{
                background-color: {theme['bg_card_subtle']};
                border-radius: 6px;
            }}
        """)

    def mousePressEvent(self, event):
        if event.button() == Qt.LeftButton:
            self.clicked.emit(self.char)


class Top3Popover(QFrame):
    candidateSelected = Signal(int, str)  # glyph_index, chosen_char
    deleteGlyph = Signal(int)             # glyph_index
    closed = Signal()

    def __init__(self, parent=None):
        super().__init__(parent, Qt.Popup | Qt.FramelessWindowHint)
        self.setAttribute(Qt.WA_DeleteOnClose, False)
        self.glyph_index: int = -1
        self.candidates: List[Tuple[str, float]] = []
        self.theme: Dict[str, Any] = {}

        self.setFixedWidth(260)
        self.main_layout = QVBoxLayout(self)
        self.main_layout.setContentsMargins(12, 12, 12, 12)
        self.main_layout.setSpacing(8)

    def set_theme(self, theme: Dict[str, Any]):
        self.theme = theme
        self.setStyleSheet(f"""
            QFrame {{
                background-color: {theme['bg_card']};
                border: 1px solid {theme['border_strong']};
                border-radius: 12px;
            }}
        """)

    def show_for_glyph(
        self,
        glyph_index: int,
        candidates: List[Tuple[str, float]],
        anchor_global_pos: QPoint,
        theme: Dict[str, Any]
    ):
        self.glyph_index = glyph_index
        self.candidates = candidates
        self.set_theme(theme)

        # Clear layout
        while self.main_layout.count():
            item = self.main_layout.takeAt(0)
            widget = item.widget()
            if widget:
                widget.deleteLater()

        # Header
        header = QHBoxLayout()
        title = QLabel("Suggestions", self)
        title.setStyleSheet(f"color: {theme['text_secondary']}; font-size: 11px; font-weight: 600; border: none;")
        shortcut_hint = QLabel("Keys 1, 2, 3", self)
        shortcut_hint.setStyleSheet(f"color: {theme['text_muted']}; font-size: 10px; border: none;")
        header.addWidget(title)
        header.addStretch()
        header.addWidget(shortcut_hint)
        self.main_layout.addLayout(header)

        # Candidate rows
        for i, (char, conf) in enumerate(candidates[:3]):
            row = CandidateRow(i + 1, char, conf, theme, self)
            row.clicked.connect(self._on_candidate_chosen)
            self.main_layout.addWidget(row)

        # Divider
        divider = QFrame(self)
        divider.setFrameShape(QFrame.HLine)
        divider.setStyleSheet(f"background-color: {theme['border_subtle']}; border: none; max-height: 1px;")
        self.main_layout.addWidget(divider)

        # Manual character input
        input_box = QHBoxLayout()
        input_box.setSpacing(6)

        self.teach_input = QLineEdit(self)
        self.teach_input.setPlaceholderText("Type any key...")
        self.teach_input.setMaxLength(2)
        self.teach_input.setAlignment(Qt.AlignCenter)
        self.teach_input.returnPressed.connect(self._on_manual_teach)
        input_box.addWidget(self.teach_input, stretch=1)

        teach_btn = QPushButton("Teach", self)
        teach_btn.setStyleSheet(f"""
            background-color: {theme['teach']};
            color: #FFFFFF;
            font-size: 12px;
            font-weight: 600;
            padding: 5px 12px;
            border: none;
            border-radius: 6px;
        """)
        teach_btn.clicked.connect(self._on_manual_teach)
        input_box.addWidget(teach_btn)
        self.main_layout.addLayout(input_box)

        # Delete glyph button
        del_btn = QPushButton("Delete this glyph (ignore)", self)
        del_btn.setStyleSheet(f"""
            background: transparent;
            color: {theme['unsure']};
            font-size: 11px;
            border: none;
            text-align: right;
            padding: 2px 4px;
        """)
        del_btn.setCursor(Qt.PointingHandCursor)
        del_btn.clicked.connect(self._on_delete_glyph)
        self.main_layout.addWidget(del_btn)

        # Position popover below the anchor point
        self.adjustSize()
        x = anchor_global_pos.x() - self.width() // 2
        y = anchor_global_pos.y() + 8
        self.move(x, y)
        self.show()
        self.teach_input.setFocus()

    def _on_candidate_chosen(self, char: str):
        self.candidateSelected.emit(self.glyph_index, char)
        self.close()

    def _on_manual_teach(self):
        val = self.teach_input.text().strip()
        if val:
            self.candidateSelected.emit(self.glyph_index, val)
            self.close()

    def _on_delete_glyph(self):
        self.deleteGlyph.emit(self.glyph_index)
        self.close()

    def keyPressEvent(self, event):
        key = event.key()
        if key == Qt.Key_1 and len(self.candidates) >= 1:
            self._on_candidate_chosen(self.candidates[0][0])
        elif key == Qt.Key_2 and len(self.candidates) >= 2:
            self._on_candidate_chosen(self.candidates[1][0])
        elif key == Qt.Key_3 and len(self.candidates) >= 3:
            self._on_candidate_chosen(self.candidates[2][0])
        elif key == Qt.Key_Escape:
            self.close()
        else:
            super().keyPressEvent(event)

    def closeEvent(self, event):
        self.closed.emit()
        super().closeEvent(event)
