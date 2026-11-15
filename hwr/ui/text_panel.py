"""
Recognized Text viewport panel with clickable character pills,
sure/unsure styling, and canvas highlight interaction.
"""

from typing import List, Dict, Any, Optional
from PySide6.QtCore import Qt, Signal, QPoint
from PySide6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel, QScrollArea,
    QFrame
)

from ..core.stroke import Glyph, CLS_NOISE


class CharPill(QLabel):
    clicked = Signal(int, QPoint)      # glyph_index, global_pos
    hovered = Signal(int)             # glyph_index
    unhovered = Signal()

    def __init__(self, glyph_index: int, glyph: Glyph, theme: Dict[str, Any], parent=None):
        super().__init__(parent)
        self.glyph_index = glyph_index
        self.glyph = glyph
        self.theme = theme

        self.setText(glyph.final_class)
        self.setAlignment(Qt.AlignCenter)
        self.setCursor(Qt.PointingHandCursor)
        self.setMinimumSize(32, 42)

        self.apply_style()

    def apply_style(self):
        theme = self.theme
        is_sure = self.glyph.is_sure
        char_color = theme["sure"] if is_sure else theme["unsure"]
        bg_color = theme["sure_bg"] if is_sure else theme["unsure_bg"]
        border_style = "none" if is_sure else f"1px dashed {theme['unsure']}"

        self.setStyleSheet(f"""
            QLabel {{
                color: {char_color};
                background-color: {bg_color};
                border: {border_style};
                border-radius: 8px;
                font-size: 24px;
                font-weight: 500;
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
                padding: 2px 6px;
            }}
            QLabel:hover {{
                border: 1.5px solid {theme['accent']};
            }}
        """)

    def enterEvent(self, event):
        self.hovered.emit(self.glyph_index)
        super().enterEvent(event)

    def leaveEvent(self, event):
        self.unhovered.emit()
        super().leaveEvent(event)

    def mousePressEvent(self, event):
        if event.button() == Qt.LeftButton:
            # Emit global anchor point (bottom center of pill)
            pt = self.mapToGlobal(QPoint(self.width() // 2, self.height()))
            self.clicked.emit(self.glyph_index, pt)


class RecognizedTextPanel(QWidget):
    glyphClicked = Signal(int, QPoint)  # glyph_index, global_anchor_point
    glyphHovered = Signal(int)          # glyph_index
    glyphUnhovered = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self.theme: Dict[str, Any] = {}
        self.glyphs: List[Glyph] = []
        self.pills: List[CharPill] = []

        main_layout = QVBoxLayout(self)
        main_layout.setContentsMargins(16, 12, 16, 12)
        main_layout.setSpacing(6)

        # Header info
        header = QHBoxLayout()
        self.title_label = QLabel("Recognized Text", self)
        self.title_label.setStyleSheet("font-size: 13px; font-weight: 600;")
        self.count_badge = QLabel("0 characters", self)
        self.count_badge.setStyleSheet("font-size: 11px; opacity: 0.7;")
        header.addWidget(self.title_label)
        header.addWidget(self.count_badge)
        header.addStretch()
        self.hint_label = QLabel("Click any character to correct or teach", self)
        self.hint_label.setStyleSheet("font-size: 11px; opacity: 0.6;")
        header.addWidget(self.hint_label)
        main_layout.addLayout(header)

        # Scroll area for flow of character pills
        self.scroll_area = QScrollArea(self)
        self.scroll_area.setWidgetResizable(True)
        self.scroll_area.setFrameShape(QFrame.NoFrame)
        self.scroll_area.setStyleSheet("background: transparent;")

        self.stream_container = QWidget()
        self.stream_layout = QVBoxLayout(self.stream_container)
        self.stream_layout.setContentsMargins(4, 4, 4, 4)
        self.stream_layout.setSpacing(8)
        self.scroll_area.setWidget(self.stream_container)

        main_layout.addWidget(self.scroll_area)

    def set_theme(self, theme: Dict[str, Any]):
        self.theme = theme
        self.title_label.setStyleSheet(f"color: {theme['text_primary']}; font-size: 13px; font-weight: 600;")
        self.count_badge.setStyleSheet(f"color: {theme['text_secondary']}; font-size: 11px;")
        self.hint_label.setStyleSheet(f"color: {theme['text_muted']}; font-size: 11px;")
        for pill in self.pills:
            pill.theme = theme
            pill.apply_style()

    def display_glyphs(self, glyphs: List[Glyph], theme: Dict[str, Any]):
        self.glyphs = glyphs
        self.theme = theme
        self.pills.clear()

        # Clear existing stream widgets
        while self.stream_layout.count():
            item = self.stream_layout.takeAt(0)
            widget = item.widget()
            if widget:
                widget.deleteLater()

        if not glyphs:
            empty_lbl = QLabel("Draw letters on the canvas above and press READ (Ctrl+Enter)", self)
            empty_lbl.setStyleSheet(f"color: {theme['text_muted']}; font-size: 14px; padding: 20px 0;")
            self.stream_layout.addWidget(empty_lbl)
            self.count_badge.setText("0 characters")
            return

        # Group glyphs by line
        lines_dict: Dict[int, List[Tuple[int, Glyph]]] = {}
        sure_count = 0
        unsure_count = 0

        for idx, g in enumerate(glyphs):
            if g.final_class == CLS_NOISE:
                continue
            lines_dict.setdefault(g.line_index, []).append((idx, g))
            if g.is_sure:
                sure_count += 1
            else:
                unsure_count += 1

        total = sure_count + unsure_count
        self.count_badge.setText(f"{total} chars ({sure_count} sure, {unsure_count} unsure)")

        for line_idx in sorted(lines_dict.keys()):
            line_row = QHBoxLayout()
            line_row.setSpacing(6)
            line_row.setAlignment(Qt.AlignLeft)

            prev_glyph = None
            for idx, g in lines_dict[line_idx]:
                if prev_glyph is not None and g.is_first_in_word:
                    # Space separator
                    spacer = QWidget()
                    spacer.setFixedWidth(16)
                    line_row.addWidget(spacer)

                pill = CharPill(idx, g, theme, self.stream_container)
                pill.clicked.connect(self.glyphClicked)
                pill.hovered.connect(self.glyphHovered)
                pill.unhovered.connect(self.glyphUnhovered)
                self.pills.append(pill)
                line_row.addWidget(pill)
                prev_glyph = g

            line_row.addStretch()
            self.stream_layout.addLayout(line_row)

        self.stream_layout.addStretch()
