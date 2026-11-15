"""
Document History drawer for browsing, searching, and reopening past recognized documents.
"""

from typing import Dict, Any, List
from PySide6.QtCore import Qt, Signal
from PySide6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel, QLineEdit,
    QPushButton, QListWidget, QListWidgetItem, QFrame
)

from ..storage.db import Database


class HistoryPanel(QWidget):
    documentSelected = Signal(int)  # document_id

    def __init__(self, db: Database, parent=None):
        super().__init__(parent)
        self.db = db
        self.theme: Dict[str, Any] = {}

        self.setFixedWidth(300)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(16, 16, 16, 16)
        layout.setSpacing(10)

        # Title
        title = QLabel("Document History", self)
        title.setStyleSheet("font-size: 15px; font-weight: 700;")
        layout.addWidget(title)

        # Search bar
        self.search_input = QLineEdit(self)
        self.search_input.setPlaceholderText("Search documents...")
        self.search_input.textChanged.connect(self.reload_documents)
        layout.addWidget(self.search_input)

        # Document list
        self.doc_list = QListWidget(self)
        self.doc_list.setStyleSheet("""
            QListWidget {
                border: 1px solid var(--border-subtle);
                border-radius: 8px;
                padding: 4px;
            }
            QListWidget::item {
                padding: 8px;
                border-radius: 6px;
            }
        """)
        self.doc_list.itemClicked.connect(self._on_item_clicked)
        layout.addWidget(self.doc_list, stretch=1)

    def set_theme(self, theme: Dict[str, Any]):
        self.theme = theme
        self.reload_documents()

    def reload_documents(self):
        query = self.search_input.text().strip()
        docs = self.db.list_documents(query)
        self.doc_list.clear()

        for d in docs:
            item = QListWidgetItem(self.doc_list)
            title = d["title"] or "Untitled Document"
            time_str = d["updated_at"][:16].replace("T", " ")
            preview = d["text"][:30].replace("\n", " ")
            item.setText(f"{title}\n{time_str} • {preview}...")
            item.setData(Qt.UserRole, d["id"])
            self.doc_list.addItem(item)

    def _on_item_clicked(self, item: QListWidgetItem):
        doc_id = item.data(Qt.UserRole)
        if doc_id:
            self.documentSelected.emit(doc_id)
