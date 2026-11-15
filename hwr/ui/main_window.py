"""
Main Application Window for HWR-LEARN.
Coordinates:
  - Menu bar and toolbars
  - Floating paper drawing canvas
  - Recognized text viewport
  - Top-3 dropdown popover
  - Slide-over Teach Mode and History drawers
  - Asynchronous background recognition worker (UI never freezes)
  - Safe file operations (Open, Append, Save As, Export)
  - Light/Dark theme switching
  - Window state persistence in SQLite
"""

import os
import sys
import json
from typing import List, Optional, Dict, Any

from PySide6.QtCore import Qt, QThread, Signal, QPoint, QTimer, QSize
from PySide6.QtGui import QAction, QKeySequence, QIcon, QColor, QClipboard, QDragEnterEvent, QDropEvent
from PySide6.QtWidgets import (
    QMainWindow, QWidget, QVBoxLayout, QHBoxLayout, QSplitter,
    QLabel, QPushButton, QFileDialog, QMessageBox, QStatusBar,
    QApplication, QFrame
)

from ..core.stroke import Stroke, Glyph, BankSample, CLS_NOISE
from ..core.driver_bridge import DriverModelBridge
from ..storage.db import Database, get_default_db_path
from ..storage.backup import export_model_json, import_model_json
from ..file_ops.text_file import LinkedTextFile, save_text_file, FileOperationError
from .theme import LIGHT_THEME, DARK_THEME, generate_stylesheet
from .canvas import DrawingCanvas
from .text_panel import RecognizedTextPanel
from .popover import Top3Popover
from .teach_panel import TeachPanel
from .history_panel import HistoryPanel
from .append_dialog import AppendPreviewDialog


class RecognitionWorker(QThread):
    finished = Signal(str, list)  # recognized_text, glyphs_list
    error = Signal(str)

    def __init__(self, model: DriverModelBridge, strokes: List[Stroke], parent=None):
        super().__init__(parent)
        self.model = model
        self.strokes = strokes

    def run(self):
        try:
            text, glyphs = self.model.recognize(self.strokes)
            self.finished.emit(text, glyphs)
        except Exception as e:
            self.error.emit(str(e))


class MainWindow(QMainWindow):
    def __init__(self, db_path: Optional[str] = None):
        super().__init__()
        self.setWindowTitle("HWR-LEARN — Handwriting OCR that learns from you")
        self.setMinimumSize(960, 680)
        self.setAcceptDrops(True)

        # Core and storage components
        self.db = Database(db_path)
        self.model = DriverModelBridge()
        self._load_bank_from_db()

        # State tracking
        self.current_theme = LIGHT_THEME
        self.current_document_id: Optional[int] = None
        self.document_title = "Untitled Document"
        self.linked_file: Optional[LinkedTextFile] = None
        self.last_folder = os.path.expanduser("~")
        self.recognized_text = ""
        self.recognized_glyphs: List[Glyph] = []
        self.skip_append_preview = False

        # Auto-read debounce timer
        self.auto_read_timer = QTimer(self)
        self.auto_read_timer.setSingleShot(True)
        self.auto_read_timer.setInterval(450)
        self.auto_read_timer.timeout.connect(self.trigger_read)
        self.auto_read_enabled = False

        # Build UI layout
        self._init_ui()
        self._setup_menus_and_shortcuts()
        self._restore_settings()
        self.apply_theme(self.current_theme)

    def _load_bank_from_db(self):
        """Populate runtime model bank from persistent SQLite samples."""
        samples = self.db.get_all_samples()
        bank_samples = [
            BankSample(
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
            for s in samples
        ]
        self.model.load_bank_samples(bank_samples)

    def _init_ui(self):
        central_widget = QWidget(self)
        central_widget.setObjectName("centralWidget")
        self.setCentralWidget(central_widget)

        root_layout = QHBoxLayout(central_widget)
        root_layout.setContentsMargins(0, 0, 0, 0)
        root_layout.setSpacing(0)

        # Main vertical content container
        main_content = QWidget(self)
        content_layout = QVBoxLayout(main_content)
        content_layout.setContentsMargins(16, 12, 16, 12)
        content_layout.setSpacing(10)

        # 1. Top Bar
        top_bar = self._create_top_bar()
        content_layout.addWidget(top_bar)

        # 2. Splitter: Floating Canvas (approx 60%) + Recognized Text Viewport
        self.splitter = QSplitter(Qt.Vertical, self)
        self.splitter.setChildrenCollapsible(False)

        # Canvas container card
        self.canvas_card = QFrame(self)
        self.canvas_card.setObjectName("cardPanel")
        canvas_layout = QVBoxLayout(self.canvas_card)
        canvas_layout.setContentsMargins(2, 2, 2, 2)
        self.canvas = DrawingCanvas(self.canvas_card)
        self.canvas.strokeFinished.connect(self._on_stroke_finished)
        self.canvas.strokesChanged.connect(self._update_status)
        canvas_layout.addWidget(self.canvas)
        self.splitter.addWidget(self.canvas_card)

        # Recognized text panel card
        self.text_card = QFrame(self)
        self.text_card.setObjectName("cardPanel")
        text_layout = QVBoxLayout(self.text_card)
        text_layout.setContentsMargins(0, 0, 0, 0)
        self.text_panel = RecognizedTextPanel(self.text_card)
        self.text_panel.glyphClicked.connect(self._on_glyph_clicked)
        self.text_panel.glyphHovered.connect(self._on_glyph_hovered)
        self.text_panel.glyphUnhovered.connect(self._on_glyph_unhovered)
        text_layout.addWidget(self.text_panel)
        self.splitter.addWidget(self.text_card)

        # 60/40 ratio default
        self.splitter.setStretchFactor(0, 6)
        self.splitter.setStretchFactor(1, 4)
        content_layout.addWidget(self.splitter, stretch=1)

        # 3. Bottom Action Bar
        action_bar = self._create_action_bar()
        content_layout.addWidget(action_bar)

        root_layout.addWidget(main_content, stretch=1)

        # 4. Slide-over Drawers (Teach Panel & History Panel)
        self.teach_panel = TeachPanel(self.db, self)
        self.teach_panel.sampleDeleted.connect(self._on_sample_deleted)
        self.teach_panel.allReset.connect(self._on_all_reset)
        self.teach_panel.hide()
        root_layout.addWidget(self.teach_panel)

        self.history_panel = HistoryPanel(self.db, self)
        self.history_panel.documentSelected.connect(self._open_history_document)
        self.history_panel.hide()
        root_layout.addWidget(self.history_panel)

        # 5. Top-3 Popover
        self.popover = Top3Popover(self)
        self.popover.candidateSelected.connect(self._on_candidate_chosen)
        self.popover.deleteGlyph.connect(self._on_delete_glyph)
        self.popover.closed.connect(self.canvas.clear_highlight_box)

        # 6. Status Bar
        self.status_bar = QStatusBar(self)
        self.setStatusBar(self.status_bar)

    def _create_top_bar(self) -> QWidget:
        bar = QWidget(self)
        layout = QHBoxLayout(bar)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(12)

        # App branding
        brand_box = QHBoxLayout()
        brand_box.setSpacing(8)
        logo = QLabel("HW", bar)
        logo.setFixedSize(30, 30)
        logo.setAlignment(Qt.AlignCenter)
        logo.setStyleSheet("background-color: #3B5BDB; color: white; font-weight: bold; border-radius: 6px; font-size: 13px;")
        brand_box.addWidget(logo)

        name = QLabel("HWR-LEARN", bar)
        name.setStyleSheet("font-weight: 700; font-size: 14px; letter-spacing: -0.3px;")
        brand_box.addWidget(name)
        layout.addLayout(brand_box)

        # Document title label
        self.title_label = QLabel(self.document_title, bar)
        self.title_label.setStyleSheet("font-size: 13px; font-weight: 500; opacity: 0.85;")
        layout.addWidget(self.title_label)

        # Linked file chip
        self.linked_chip = QFrame(bar)
        self.linked_chip.setObjectName("cardPanel")
        chip_layout = QHBoxLayout(self.linked_chip)
        chip_layout.setContentsMargins(8, 2, 8, 2)
        chip_layout.setSpacing(6)

        self.chip_status_dot = QLabel("●", self.linked_chip)
        self.chip_status_dot.setStyleSheet("color: #2B8A3E; font-size: 10px;")
        chip_layout.addWidget(self.chip_status_dot)

        self.chip_file_label = QLabel("No file linked", self.linked_chip)
        self.chip_file_label.setStyleSheet("font-size: 11px; font-family: monospace;")
        chip_layout.addWidget(self.chip_file_label)

        self.chip_enc_label = QLabel("UTF-8", self.linked_chip)
        self.chip_enc_label.setStyleSheet("font-size: 10px; font-family: monospace; opacity: 0.6;")
        chip_layout.addWidget(self.chip_enc_label)

        unlink_btn = QPushButton("✕", self.linked_chip)
        unlink_btn.setFixedSize(16, 16)
        unlink_btn.setToolTip("Unlink file")
        unlink_btn.setStyleSheet("background: transparent; border: none; font-size: 10px; padding: 0;")
        unlink_btn.clicked.connect(self.unlink_file)
        chip_layout.addWidget(unlink_btn)

        self.linked_chip.hide()
        layout.addWidget(self.linked_chip)

        layout.addStretch()

        # Mode Buttons
        mode_box = QHBoxLayout()
        mode_box.setSpacing(2)
        self.mode_btns = []
        for mode_idx, mode_name in enumerate(["AUTO", "ABC", "abc", "123"]):
            btn = QPushButton(mode_name, bar)
            btn.setCheckable(True)
            btn.setChecked(mode_idx == 0)
            btn.clicked.connect(lambda _, m=mode_idx: self._set_mode(m))
            mode_box.addWidget(btn)
            self.mode_btns.append(btn)
        layout.addLayout(mode_box)

        # Drawers toggle buttons
        self.teach_toggle_btn = QPushButton("Teach Mode", bar)
        self.teach_toggle_btn.clicked.connect(self._toggle_teach_drawer)
        layout.addWidget(self.teach_toggle_btn)

        self.history_toggle_btn = QPushButton("History", bar)
        self.history_toggle_btn.clicked.connect(self._toggle_history_drawer)
        layout.addWidget(self.history_toggle_btn)

        # Theme switch button
        self.theme_btn = QPushButton("🌙" if self.current_theme["name"] == "light" else "☀️", bar)
        self.theme_btn.setFixedSize(34, 30)
        self.theme_btn.setToolTip("Toggle Light / Dark Theme")
        self.theme_btn.clicked.connect(self.toggle_theme)
        layout.addWidget(self.theme_btn)

        return bar

    def _create_action_bar(self) -> QWidget:
        bar = QWidget(self)
        layout = QHBoxLayout(bar)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(8)

        # Primary READ button
        self.read_btn = QPushButton("READ", bar)
        self.read_btn.setObjectName("primaryButton")
        self.read_btn.setToolTip("Recognize handwriting (Ctrl+Enter)")
        self.read_btn.clicked.connect(self.trigger_read)
        layout.addWidget(self.read_btn)

        # Canvas tools
        clear_btn = QPushButton("Clear", bar)
        clear_btn.setToolTip("Clear drawing canvas (Ctrl+K)")
        clear_btn.clicked.connect(self.canvas.clear_canvas)
        layout.addWidget(clear_btn)

        undo_stroke_btn = QPushButton("Undo Stroke", bar)
        undo_stroke_btn.setToolTip("Undo last pen stroke (Ctrl+Z)")
        undo_stroke_btn.clicked.connect(self.canvas.undo_stroke)
        layout.addWidget(undo_stroke_btn)

        redo_stroke_btn = QPushButton("Redo", bar)
        redo_stroke_btn.setToolTip("Redo pen stroke (Ctrl+Y)")
        redo_stroke_btn.clicked.connect(self.canvas.redo_stroke)
        layout.addWidget(redo_stroke_btn)

        # Undo Teach button
        self.undo_teach_btn = QPushButton("Undo Teach", bar)
        self.undo_teach_btn.setToolTip("Remove most recently taught sample (Ctrl+Shift+Z)")
        self.undo_teach_btn.clicked.connect(self.undo_teach)
        layout.addWidget(self.undo_teach_btn)

        layout.addStretch()

        # File actions
        append_btn = QPushButton("Append to File", bar)
        append_btn.setToolTip("Safely append recognized text to linked file (Ctrl+Shift+A)")
        append_btn.clicked.connect(self.append_to_file)
        layout.addWidget(append_btn)

        save_btn = QPushButton("Save As...", bar)
        save_btn.setToolTip("Save recognized text as new .txt file (Ctrl+S)")
        save_btn.clicked.connect(self.save_as_file)
        layout.addWidget(save_btn)

        copy_btn = QPushButton("Copy Text", bar)
        copy_btn.setToolTip("Copy recognized text to clipboard (Ctrl+C)")
        copy_btn.clicked.connect(self.copy_to_clipboard)
        layout.addWidget(copy_btn)

        return bar

    def _setup_menus_and_shortcuts(self):
        menubar = self.menuBar()

        # File Menu
        file_menu = menubar.addMenu("&File")

        new_act = QAction("&New Canvas", self)
        new_act.setShortcut(QKeySequence("Ctrl+N"))
        new_act.triggered.connect(self.canvas.clear_canvas)
        file_menu.addAction(new_act)

        open_act = QAction("&Open Text File...", self)
        open_act.setShortcut(QKeySequence("Ctrl+O"))
        open_act.triggered.connect(self.open_text_file)
        file_menu.addAction(open_act)

        file_menu.addSeparator()

        save_act = QAction("&Save As...", self)
        save_act.setShortcut(QKeySequence("Ctrl+S"))
        save_act.triggered.connect(self.save_as_file)
        file_menu.addAction(save_act)

        append_act = QAction("&Append to File...", self)
        append_act.setShortcut(QKeySequence("Ctrl+Shift+A"))
        append_act.triggered.connect(self.append_to_file)
        file_menu.addAction(append_act)

        file_menu.addSeparator()

        export_act = QAction("&Export Learned Model...", self)
        export_act.triggered.connect(self.export_model)
        file_menu.addAction(export_act)

        import_act = QAction("&Import Model...", self)
        import_act.triggered.connect(self.import_model)
        file_menu.addAction(import_act)

        file_menu.addSeparator()

        exit_act = QAction("E&xit", self)
        exit_act.setShortcut(QKeySequence("Ctrl+Q"))
        exit_act.triggered.connect(self.close)
        file_menu.addAction(exit_act)

        # Edit Menu
        edit_menu = menubar.addMenu("&Edit")

        read_act = QAction("&Read Canvas", self)
        read_act.setShortcut(QKeySequence("Ctrl+Return"))
        read_act.triggered.connect(self.trigger_read)
        edit_menu.addAction(read_act)

        undo_s_act = QAction("&Undo Stroke", self)
        undo_s_act.setShortcut(QKeySequence("Ctrl+Z"))
        undo_s_act.triggered.connect(self.canvas.undo_stroke)
        edit_menu.addAction(undo_s_act)

        redo_s_act = QAction("&Redo Stroke", self)
        redo_s_act.setShortcut(QKeySequence("Ctrl+Y"))
        redo_s_act.triggered.connect(self.canvas.redo_stroke)
        edit_menu.addAction(redo_s_act)

        undo_t_act = QAction("Undo Last &Teach", self)
        undo_t_act.setShortcut(QKeySequence("Ctrl+Shift+Z"))
        undo_t_act.triggered.connect(self.undo_teach)
        edit_menu.addAction(undo_t_act)

        edit_menu.addSeparator()

        copy_act = QAction("&Copy Text", self)
        copy_act.setShortcut(QKeySequence("Ctrl+C"))
        copy_act.triggered.connect(self.copy_to_clipboard)
        edit_menu.addAction(copy_act)

        # View Menu
        view_menu = menubar.addMenu("&View")

        theme_act = QAction("&Toggle Theme", self)
        theme_act.triggered.connect(self.toggle_theme)
        view_menu.addAction(theme_act)

        teach_act = QAction("&Teach Mode Panel", self)
        teach_act.triggered.connect(self._toggle_teach_drawer)
        view_menu.addAction(teach_act)

        hist_act = QAction("&Document History", self)
        hist_act.triggered.connect(self._toggle_history_drawer)
        view_menu.addAction(hist_act)

        # Help Menu
        help_menu = menubar.addMenu("&Help")
        tour_act = QAction("&Guided Tour...", self)
        tour_act.triggered.connect(self.show_guided_tour)
        help_menu.addAction(tour_act)

        about_act = QAction("&About HWR-LEARN", self)
        about_act.triggered.connect(self.show_about_dialog)
        help_menu.addAction(about_act)

    # Theme Management
    def apply_theme(self, theme: Dict[str, Any]):
        self.current_theme = theme
        qss = generate_stylesheet(theme)
        self.setStyleSheet(qss)
        self.canvas.set_theme_colors(theme)
        self.text_panel.set_theme(theme)
        self.popover.set_theme(theme)
        self.teach_panel.set_theme(theme)
        self.history_panel.set_theme(theme)
        self.theme_btn.setText("🌙" if theme["name"] == "light" else "☀️")
        self.db.set_setting("theme", theme["name"])
        self._update_status()

    def toggle_theme(self):
        new_theme = DARK_THEME if self.current_theme["name"] == "light" else LIGHT_THEME
        self.apply_theme(new_theme)

    # Recognition Execution (Async Worker)
    def _on_stroke_finished(self):
        if self.auto_read_enabled:
            self.auto_read_timer.start()

    def trigger_read(self):
        strokes = self.canvas.get_core_strokes()
        if not strokes:
            self.status_bar.showMessage("Nothing to read — draw some handwriting first.", 3000)
            return

        self.read_btn.setEnabled(False)
        self.status_bar.showMessage("Recognizing handwriting...")

        # Worker thread ensures UI never freezes
        self.worker = RecognitionWorker(self.model, strokes, self)
        self.worker.finished.connect(self._on_recognition_finished)
        self.worker.error.connect(self._on_recognition_error)
        self.worker.start()

    def _on_recognition_finished(self, text: str, glyphs: List[Glyph]):
        self.read_btn.setEnabled(True)
        self.recognized_text = text
        self.recognized_glyphs = glyphs
        self.text_panel.display_glyphs(glyphs, self.current_theme)

        # Auto-save document snapshot to SQLite
        self.current_document_id = self.db.save_document(
            title=self.document_title,
            text=text,
            linked_file_path=self.linked_file.file_path if self.linked_file else None,
            doc_id=self.current_document_id
        )

        sure_count = sum(1 for g in glyphs if g.is_sure)
        unsure_count = len(glyphs) - sure_count
        self.status_bar.showMessage(f"Recognized {len(glyphs)} characters ({sure_count} sure, {unsure_count} unsure)", 4000)
        self._update_status()

    def _on_recognition_error(self, err_msg: str):
        self.read_btn.setEnabled(True)
        self.status_bar.showMessage(f"Recognition error: {err_msg}", 5000)

    # Popover & Interactive Teaching
    def _on_glyph_clicked(self, glyph_index: int, anchor_point: QPoint):
        if 0 <= glyph_index < len(self.recognized_glyphs):
            g = self.recognized_glyphs[glyph_index]
            self.canvas.set_highlight_box(g.x1, g.y1, g.x2, g.y2)
            self.popover.show_for_glyph(glyph_index, g.candidates, anchor_point, self.current_theme)

    def _on_glyph_hovered(self, glyph_index: int):
        if 0 <= glyph_index < len(self.recognized_glyphs):
            g = self.recognized_glyphs[glyph_index]
            self.canvas.set_highlight_box(g.x1, g.y1, g.x2, g.y2)

    def _on_glyph_unhovered(self):
        if not self.popover.isVisible():
            self.canvas.clear_highlight_box()

    def _on_candidate_chosen(self, glyph_index: int, new_char: str):
        if 0 <= glyph_index < len(self.recognized_glyphs):
            glyph = self.recognized_glyphs[glyph_index]

            # 1. Teach model in memory
            sample = self.model.teach_glyph(glyph, new_char)

            # 2. Persist to SQLite immediately (WAL, synchronous=FULL)
            self.db.add_sample(
                label=sample.label,
                grid8=sample.grid8,
                grid57=sample.grid57,
                aspect=sample.aspect,
                flags=sample.flags,
                is_tiny=sample.is_tiny,
                tiny_key=sample.tiny_key
            )

            # 3. Refresh views
            self.text_panel.display_glyphs(self.recognized_glyphs, self.current_theme)
            self.teach_panel.reload_samples()
            self._update_status()
            self.status_bar.showMessage(f"Learned '{new_char}' — model reinforced immediately.", 4000)

    def _on_delete_glyph(self, glyph_index: int):
        if 0 <= glyph_index < len(self.recognized_glyphs):
            g = self.recognized_glyphs[glyph_index]
            from ..core.stroke import CLS_NOISE
            g.final_class = CLS_NOISE
            self.text_panel.display_glyphs(self.recognized_glyphs, self.current_theme)
            self.status_bar.showMessage("Glyph removed.", 3000)

    # Undo Teach
    def undo_teach(self):
        res = self.db.undo_last_teach()
        if res is None:
            self.status_bar.showMessage("Nothing to undo in teach history.", 3000)
            return

        label = res["label"]
        self._load_bank_from_db()
        self.teach_panel.reload_samples()
        self.trigger_read()
        self.status_bar.showMessage(f"Undid teaching of sample '{label}'. Re-read screen.", 4000)

    def _on_sample_deleted(self):
        self._load_bank_from_db()
        self._update_status()

    def _on_all_reset(self):
        self.model.reset_model()
        self._update_status()
        self.trigger_read()

    # Drawers Toggle
    def _toggle_teach_drawer(self):
        self.teach_panel.setVisible(not self.teach_panel.isVisible())

    def _toggle_history_drawer(self):
        self.history_panel.setVisible(not self.history_panel.isVisible())

    def _set_mode(self, mode_idx: int):
        self.model.mode = mode_idx
        for i, btn in enumerate(self.mode_btns):
            btn.setChecked(i == mode_idx)
        if self.canvas.strokes:
            self.trigger_read()

    # File Operations
    def open_text_file(self):
        file_path, _ = QFileDialog.getOpenFileName(
            self, "Open Text File", self.last_folder, "Text Files (*.txt);;All Files (*.*)"
        )
        if not file_path:
            return

        try:
            self.linked_file = LinkedTextFile(file_path)
            self.last_folder = os.path.dirname(file_path)
            self.db.set_setting("last_folder", self.last_folder)

            # Update UI linked chip
            self.chip_file_label.setText(os.path.basename(file_path))
            self.chip_enc_label.setText(f"{self.linked_file.encoding.upper()} • {'CRLF' if self.linked_file.newline_style == '\r\n' else 'LF'}")
            self.linked_chip.show()

            self.status_bar.showMessage(f"Linked file: {file_path}", 4000)
        except Exception as e:
            QMessageBox.critical(self, "Error Opening File", str(e))

    def unlink_file(self):
        self.linked_file = None
        self.linked_chip.hide()
        self.status_bar.showMessage("File unlinked.", 3000)

    def append_to_file(self):
        if not self.recognized_text:
            QMessageBox.information(self, "No Text", "Please recognize some handwriting text first.")
            return

        if not self.linked_file:
            self.open_text_file()
            if not self.linked_file:
                return

        # Show preview dialog unless "don't ask again" was checked
        if not self.skip_append_preview:
            dlg = AppendPreviewDialog(
                file_path=self.linked_file.file_path,
                encoding=self.linked_file.encoding,
                newline=self.linked_file.newline_style,
                text_to_append=self.recognized_text,
                theme=self.current_theme,
                parent=self
            )
            if dlg.exec() != AppendPreviewDialog.Accepted:
                return
            if dlg.dont_ask_again:
                self.skip_append_preview = True

        try:
            self.linked_file.append_text(self.recognized_text)
            self.status_bar.showMessage(f"Appended text safely to {os.path.basename(self.linked_file.file_path)}", 4000)
        except FileOperationError as e:
            QMessageBox.warning(self, "File Append Warning", str(e))
        except Exception as e:
            QMessageBox.critical(self, "Append Error", str(e))

    def save_as_file(self):
        if not self.recognized_text:
            QMessageBox.information(self, "No Text", "No recognized text to save.")
            return

        file_path, selected_filter = QFileDialog.getSaveFileName(
            self, "Save Text File", self.last_folder, "UTF-8 Text (*.txt);;Windows-1252 Text (*.txt);;All Files (*.*)"
        )
        if not file_path:
            return

        encoding = "windows-1252" if "Windows-1252" in selected_filter else "utf-8"
        try:
            save_text_file(file_path, self.recognized_text, encoding=encoding, newline="\r\n" if os.name == "nt" else "\n")
            self.last_folder = os.path.dirname(file_path)
            self.status_bar.showMessage(f"Saved to {file_path}", 4000)
        except Exception as e:
            QMessageBox.critical(self, "Save Error", str(e))

    def copy_to_clipboard(self):
        if self.recognized_text:
            QApplication.clipboard().setText(self.recognized_text)
            self.status_bar.showMessage("Recognized text copied to clipboard.", 3000)

    def export_model(self):
        file_path, _ = QFileDialog.getSaveFileName(
            self, "Export Learned Model", self.last_folder, "JSON Model (*.json)"
        )
        if file_path:
            export_model_json(self.db, file_path)
            QMessageBox.information(self, "Exported", f"Learned model exported to:\n{file_path}")

    def import_model(self):
        file_path, _ = QFileDialog.getOpenFileName(
            self, "Import Learned Model", self.last_folder, "JSON Model (*.json);;LEARN.DAT (DOSBox) (*.DAT);;All Files (*.*)"
        )
        if not file_path:
            return

        try:
            if file_path.lower().endswith(".dat"):
                # Legacy LEARN.DAT format
                with open(file_path, "rb") as f:
                    data = f.read()
                from ..storage.backup import load_legacy_learn_dat
                imported = load_legacy_learn_dat(data)
                count = 0
                for s in imported["bank_samples"]:
                    self.db.add_sample(s["label"], s["grid8"], s["grid57"], s["aspect"], s["flags"])
                    count += 1
                self._load_bank_from_db()
                QMessageBox.information(self, "Imported", f"Successfully imported {count} samples from legacy LEARN.DAT!")
            else:
                count = import_model_json(self.db, file_path)
                self._load_bank_from_db()
                QMessageBox.information(self, "Imported", f"Successfully imported {count} samples from {os.path.basename(file_path)}!")
            self.teach_panel.reload_samples()
            self._update_status()
        except Exception as e:
            QMessageBox.critical(self, "Import Error", f"Failed to import file: {e}")

    def _open_history_document(self, doc_id: int):
        doc = self.db.get_document(doc_id)
        if doc:
            self.recognized_text = doc["text"]
            self.title_label.setText(doc["title"])
            self.status_bar.showMessage(f"Opened document: {doc['title']}", 3000)

    # Drag and drop .txt support
    def dragEnterEvent(self, event: QDragEnterEvent):
        if event.mimeData().hasUrls():
            for url in event.mimeData().urls():
                if url.toLocalFile().lower().endswith((".txt", ".dat", ".json")):
                    event.acceptProposedAction()
                    return

    def dropEvent(self, event: QDropEvent):
        for url in event.mimeData().urls():
            file_path = url.toLocalFile()
            if file_path.lower().endswith(".txt"):
                self.linked_file = LinkedTextFile(file_path)
                self.chip_file_label.setText(os.path.basename(file_path))
                self.chip_enc_label.setText(self.linked_file.encoding.upper())
                self.linked_chip.show()
                self.status_bar.showMessage(f"Linked dropped file: {file_path}", 4000)
                break
            elif file_path.lower().endswith(".dat") or file_path.lower().endswith(".json"):
                # Trigger import
                self.import_model()

    # Settings & State Persistence
    def _restore_settings(self):
        theme_setting = self.db.get_setting("theme", "light")
        self.current_theme = DARK_THEME if theme_setting == "dark" else LIGHT_THEME
        self.last_folder = self.db.get_setting("last_folder", os.path.expanduser("~"))

        geom = self.db.get_setting("window_geometry")
        if geom:
            try:
                g = json.loads(geom)
                self.resize(g.get("width", 1080), g.get("height", 720))
            except Exception:
                pass

    def closeEvent(self, event):
        # Save geometry
        geom = {"width": self.width(), "height": self.height()}
        self.db.set_setting("window_geometry", json.dumps(geom))
        self.db.close()
        if hasattr(self.model, "close"):
            self.model.close()
        super().closeEvent(event)

    def _update_status(self):
        taught_count = self.db.get_sample_count()
        classes_count = self.db.get_classes_count()
        mode_str = ["AUTO", "ABC", "abc", "123"][self.model.mode]
        file_info = os.path.basename(self.linked_file.file_path) if self.linked_file else "No file linked"
        backend = getattr(self.model, "backend_name", "Core")
        self.status_bar.showMessage(
            f"Engine: {backend} | Mode: {mode_str} | Taught: {taught_count} samples ({classes_count} classes) | Linked: {file_info}"
        )

    def show_guided_tour(self):
        tour_msg = (
            "Welcome to HWR-LEARN!\n\n"
            "1. DRAW: Write natural handwriting using your mouse, stylus, or touch.\n"
            "2. READ: Press the big READ button (or Ctrl+Enter) to transcribe your ink.\n"
            "3. CORRECT & TEACH: Click any character in the text view to inspect the Top-3 suggestions, "
            "or type any character to immediately reinforce learning.\n"
            "4. SAFE APPEND: Link an existing .txt file to automatically append newly transcribed text without overwriting.\n\n"
            "Enjoy writing!"
        )
        QMessageBox.information(self, "HWR-LEARN Quick Tour", tour_msg)

    def show_about_dialog(self):
        about_msg = (
            "HWR-LEARN Desktop Application\n"
            "Version 2.0 (Modern Native Rewrite)\n\n"
            "Combines 4,369 font skeleton nearest-neighbor seeds, multi-prototype matching, "
            "and an online trainable 62-class perceptron with shift-tolerant SQLite bank memory.\n\n"
            "100% Offline • Zero Network Calls • Cross-Platform"
        )
        QMessageBox.about(self, "About HWR-LEARN", about_msg)
