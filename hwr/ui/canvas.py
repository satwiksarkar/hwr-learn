"""
Floating Paper Drawing Canvas for HWR-LEARN.
Provides smooth anti-aliased ink rendering, guidelines, mouse/pen/touch input,
stroke undo/redo, and glyph highlighting.
"""

from typing import List, Optional, Tuple, Dict, Any
from PySide6.QtCore import Qt, QPointF, QRectF, Signal
from PySide6.QtGui import QPainter, QPen, QColor, QPainterPath, QPaintEvent, QMouseEvent
from PySide6.QtWidgets import QWidget

from ..core.stroke import Point, Stroke


class DrawingCanvas(QWidget):
    strokeFinished = Signal()
    strokesChanged = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setMouseTracking(True)
        self.setAttribute(Qt.WA_StaticContents)
        self.setFocusPolicy(Qt.StrongFocus)

        # Stroke history stacks
        self.strokes: List[List[Point]] = []
        self._redo_strokes: List[List[Point]] = []
        self._current_stroke: List[Point] = []
        self._is_drawing = False

        # Visual settings
        self.pen_color = QColor("#F59E0B")  # amber yellow default ink
        self.pen_width = 3.5
        self.show_guidelines = True
        self.bg_color = QColor("#FFFFFF")
        self.guideline_color = QColor("#CED4DA")

        # Bounding box highlighting for currently selected / hovered glyph
        self._highlight_rect: Optional[QRectF] = None
        self._highlight_color = QColor("#3B5BDB")

    def set_theme_colors(self, theme: Dict[str, Any]):
        self.bg_color = QColor(theme["bg_canvas"])
        self.guideline_color = QColor(theme["canvas_guideline"])
        self._highlight_color = QColor(theme["accent"])
        self.update()

    def set_highlight_box(self, x1: int, y1: int, x2: int, y2: int):
        self._highlight_rect = QRectF(x1 - 2, y1 - 2, (x2 - x1) + 4, (y2 - y1) + 4)
        self.update()

    def clear_highlight_box(self):
        if self._highlight_rect is not None:
            self._highlight_rect = None
            self.update()

    def toggle_guidelines(self, enabled: bool):
        self.show_guidelines = enabled
        self.update()

    def set_pen_color(self, hex_color: str):
        self.pen_color = QColor(hex_color)

    def set_pen_width(self, width: float):
        self.pen_width = max(1.0, min(10.0, width))

    def get_core_strokes(self) -> List[Stroke]:
        """Convert drawn strokes to core engine Stroke objects."""
        core_strokes = []
        for s in self.strokes:
            if len(s) >= 2:
                core_strokes.append(Stroke(points=list(s)))
        return core_strokes

    def undo_stroke(self):
        if self.strokes:
            s = self.strokes.pop()
            self._redo_strokes.append(s)
            self.update()
            self.strokesChanged.emit()

    def redo_stroke(self):
        if self._redo_strokes:
            s = self._redo_strokes.pop()
            self.strokes.append(s)
            self.update()
            self.strokesChanged.emit()

    def clear_canvas(self):
        if self.strokes:
            self.strokes.clear()
            self._redo_strokes.clear()
            self._highlight_rect = None
            self.update()
            self.strokesChanged.emit()

    # Mouse & Pen Events
    def mousePressEvent(self, event: QMouseEvent):
        if event.button() == Qt.LeftButton:
            self._is_drawing = True
            pos = event.position()
            self._current_stroke = [Point(pos.x(), pos.y())]
            self._redo_strokes.clear()
            self.update()

    def mouseMoveEvent(self, event: QMouseEvent):
        if self._is_drawing and (event.buttons() & Qt.LeftButton):
            pos = event.position()
            self._current_stroke.append(Point(pos.x(), pos.y()))
            self.update()

    def mouseReleaseEvent(self, event: QMouseEvent):
        if event.button() == Qt.LeftButton and self._is_drawing:
            self._is_drawing = False
            if len(self._current_stroke) >= 2:
                self.strokes.append(list(self._current_stroke))
                self.strokesChanged.emit()
                self.strokeFinished.emit()
            self._current_stroke = []
            self.update()

    def paintEvent(self, event: QPaintEvent):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.Antialiasing, True)

        # 1. Background
        painter.fillRect(self.rect(), self.bg_color)

        # 2. Writing Guidelines (baseline & x-height)
        if self.show_guidelines:
            h = self.height()
            w = self.width()
            # Draw standard 2 guide bands across middle
            y_base1 = int(h * 0.45)
            y_x1 = int(y_base1 - 42)
            y_base2 = int(h * 0.75)
            y_x2 = int(y_base2 - 42)

            guide_pen_base = QPen(self.guideline_color, 1.2, Qt.DashLine)
            guide_pen_x = QPen(self.guideline_color, 1.0, Qt.DotLine)

            for y_b, y_x in [(y_base1, y_x1), (y_base2, y_x2)]:
                painter.setPen(guide_pen_x)
                painter.drawLine(30, y_x, w - 30, y_x)
                painter.setPen(guide_pen_base)
                painter.drawLine(30, y_b, w - 30, y_b)

        # 3. Highlight box if active
        if self._highlight_rect:
            highlight_pen = QPen(self._highlight_color, 2.0, Qt.SolidLine)
            painter.setPen(highlight_pen)
            brush_color = QColor(self._highlight_color)
            brush_color.setAlpha(35)
            painter.setBrush(brush_color)
            painter.drawRoundedRect(self._highlight_rect, 6, 6)

        # 4. Render all completed strokes
        ink_pen = QPen(self.pen_color, self.pen_width, Qt.SolidLine, Qt.RoundCap, Qt.RoundJoin)
        painter.setPen(ink_pen)
        painter.setBrush(Qt.NoBrush)

        for stroke in self.strokes:
            self._draw_smooth_stroke(painter, stroke)

        # 5. Render active in-progress stroke
        if self._current_stroke:
            self._draw_smooth_stroke(painter, self._current_stroke)

    def _draw_smooth_stroke(self, painter: QPainter, pts: List[Point]):
        if not pts:
            return
        if len(pts) == 1:
            painter.drawPoint(QPointF(pts[0].x, pts[0].y))
            return

        path = QPainterPath()
        path.moveTo(QPointF(pts[0].x, pts[0].y))

        # Quad curve smoothing between midpoints
        for i in range(1, len(pts)):
            p0 = pts[i - 1]
            p1 = pts[i]
            mid_x = (p0.x + p1.x) / 2.0
            mid_y = (p0.y + p1.y) / 2.0
            path.quadTo(QPointF(p0.x, p0.y), QPointF(mid_x, mid_y))

        path.lineTo(QPointF(pts[-1].x, pts[-1].y))
        painter.drawPath(path)
