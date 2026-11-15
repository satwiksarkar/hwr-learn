"""
Safe Append Preview Dialog for HWR-LEARN.
Displays file path, encoding, newline style, safety backup notice,
and exact text slice preview before appending.
"""

from typing import Dict, Any
from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QDialog, QVBoxLayout, QHBoxLayout, QLabel, QTextEdit,
    QCheckBox, QPushButton, QFrame
)


class AppendPreviewDialog(QDialog):
    def __init__(
        self,
        file_path: str,
        encoding: str,
        newline: str,
        text_to_append: str,
        theme: Dict[str, Any],
        parent=None
    ):
        super().__init__(parent)
        self.setWindowTitle("Append to File Preview")
        self.setFixedWidth(460)
        self.dont_ask_again = False

        layout = QVBoxLayout(self)
        layout.setContentsMargins(20, 20, 20, 20)
        layout.setSpacing(14)

        # Title
        title = QLabel("Append to File", self)
        title.setStyleSheet("font-size: 16px; font-weight: 700;")
        layout.addWidget(title)

        # File metadata info box
        info_box = QFrame(self)
        info_box.setStyleSheet(f"""
            QFrame {{
                background-color: {theme['bg_card_subtle']};
                border: 1px solid {theme['border_subtle']};
                border-radius: 8px;
                padding: 10px;
            }}
        """)
        info_layout = QVBoxLayout(info_box)
        info_layout.setSpacing(6)

        def add_info_row(label_text, val_text, color=None):
            row = QHBoxLayout()
            lbl = QLabel(label_text, info_box)
            lbl.setStyleSheet(f"color: {theme['text_muted']}; font-size: 12px; border: none;")
            val = QLabel(val_text, info_box)
            val_col = color if color else theme['text_primary']
            val.setStyleSheet(f"color: {val_col}; font-family: monospace; font-size: 12px; font-weight: 600; border: none;")
            row.addWidget(lbl)
            row.addStretch()
            row.addWidget(val)
            info_layout.addLayout(row)

        nl_desc = "CRLF (\\r\\n)" if newline == "\r\n" else "LF (\\n)"
        add_info_row("Target File:", file_path[-35:] if len(file_path) > 35 else file_path)
        add_info_row("Detected Encoding:", encoding.upper(), theme['sure'])
        add_info_row("Line Ending Style:", nl_desc)
        add_info_row("Safety Backup:", f"{file_path}.bak")
        layout.addWidget(info_box)

        # Text slice preview
        preview_label = QLabel("Text to be appended at end-of-file:", self)
        preview_label.setStyleSheet("font-size: 12px; font-weight: 600;")
        layout.addWidget(preview_label)

        self.preview_box = QTextEdit(self)
        self.preview_box.setPlainText(text_to_append)
        self.preview_box.setReadOnly(True)
        self.preview_box.setFixedHeight(100)
        self.preview_box.setStyleSheet(f"""
            QTextEdit {{
                background-color: {theme['bg_canvas']};
                color: {theme['text_primary']};
                border: 1px solid {theme['border_subtle']};
                border-radius: 8px;
                font-family: monospace;
                font-size: 13px;
                padding: 8px;
            }}
        """)
        layout.addWidget(self.preview_box)

        # "Don't ask again" checkbox
        self.chk_dont_ask = QCheckBox("Don't ask again this session", self)
        self.chk_dont_ask.setStyleSheet("font-size: 12px;")
        layout.addWidget(self.chk_dont_ask)

        # Action buttons
        btn_box = QHBoxLayout()
        btn_box.setSpacing(10)
        btn_box.addStretch()

        cancel_btn = QPushButton("Cancel", self)
        cancel_btn.clicked.connect(self.reject)
        btn_box.addWidget(cancel_btn)

        append_btn = QPushButton("Confirm Append", self)
        append_btn.setObjectName("primaryButton")
        append_btn.setStyleSheet(f"""
            background-color: {theme['sure']};
            color: #FFFFFF;
            font-weight: 600;
            padding: 8px 18px;
            border-radius: 8px;
            border: none;
        """)
        append_btn.clicked.connect(self._on_confirm)
        btn_box.addWidget(append_btn)
        layout.addLayout(btn_box)

    def _on_confirm(self):
        self.dont_ask_again = self.chk_dont_ask.isChecked()
        self.accept()
