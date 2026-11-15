"""
Stroke and glyph point processing.
Lightweight point, stroke, and glyph data classes for UI canvas and driver bridge.
Zero numpy dependencies.
"""

from dataclasses import dataclass, field
from typing import List, Tuple, Optional, Any

CLS_NOISE = chr(1)


@dataclass
class Point:
    x: float
    y: float


@dataclass
class Stroke:
    points: List[Point] = field(default_factory=list)

    @property
    def min_x(self) -> int:
        if not self.points:
            return 0
        return int(min(p.x for p in self.points))

    @property
    def max_x(self) -> int:
        if not self.points:
            return 0
        return int(max(p.x for p in self.points))

    @property
    def min_y(self) -> int:
        if not self.points:
            return 0
        return int(min(p.y for p in self.points))

    @property
    def max_y(self) -> int:
        if not self.points:
            return 0
        return int(max(p.y for p in self.points))

    @property
    def width(self) -> int:
        return max(1, self.max_x - self.min_x + 1)

    @property
    def height(self) -> int:
        return max(1, self.max_y - self.min_y + 1)


@dataclass
class Glyph:
    strokes: List[Stroke] = field(default_factory=list)
    line_index: int = 0
    word_index: int = 0
    is_first_in_word: bool = False

    # Raw bounds
    x1: int = 0
    x2: int = 0
    y1: int = 0
    y2: int = 0

    # Raster features (bytes)
    grid8: bytes = b"\x00" * 8
    grid57: bytes = b"\x00" * 7
    aspect: int = 0
    ratio: int = 0
    flags: int = 0  # b0 tall, b1 desc, b2 tiny, b3 dash, b4 abs-rule, b5 bank-hit

    # Classification results
    raw_class: str = ""
    group_id: int = 0xFF
    margin: int = 0
    final_class: str = ""
    is_sure: bool = False  # True = green, False = red (unsure)
    confidence: float = 0.0
    candidates: List[Tuple[str, float]] = field(default_factory=list)

    def recompute_bounds(self):
        if not self.strokes:
            self.x1 = self.x2 = self.y1 = self.y2 = 0
            return
        self.x1 = min(s.min_x for s in self.strokes)
        self.x2 = max(s.max_x for s in self.strokes) + 1
        self.y1 = min(s.min_y for s in self.strokes)
        self.y2 = max(s.max_y for s in self.strokes) + 1

    @property
    def width(self) -> int:
        return max(1, self.x2 - self.x1)

    @property
    def height(self) -> int:
        return max(1, self.y2 - self.y1)


@dataclass
class BankSample:
    id: Optional[int]
    label: str
    grid8: bytes
    grid57: bytes
    aspect: int
    flags: int
    is_tiny: bool = False
    tiny_key: int = 0
    created_at: Optional[str] = None
    source: str = "user"


def split_connected_glyph(glyph: Glyph, line_median_width: int = 18) -> List[Glyph]:
    """
    Fix 5: Splits touching cursive letters ('ar', 'ou') written in one stroke
    by finding the vertical ink density valley.
    Zero numpy dependencies.
    """
    w = glyph.width
    threshold_w = max(28, int(line_median_width * 1.65))
    if w < threshold_w or not glyph.strokes:
        return [glyph]

    pts = glyph.strokes[0].points
    if len(pts) < 15:
        return [glyph]

    min_x = glyph.x1
    density = [0] * (w + 1)
    for p in pts:
        idx = int(p.x - min_x)
        if 0 <= idx <= w:
            density[idx] += 1

    min_idx = int(w * 0.35)
    max_idx = int(w * 0.65)
    valley_x = -1
    min_d = 999999
    for i in range(min_idx, max_idx + 1):
        if density[i] < min_d:
            min_d = density[i]
            valley_x = min_x + i

    if min_d <= 3 and valley_x != -1:
        candidates = range(5, len(pts) - 5)
        idx_split = min(candidates, key=lambda i: abs(pts[i].x - valley_x))
        g1 = Glyph(strokes=[Stroke(pts[:idx_split])])
        g2 = Glyph(strokes=[Stroke(pts[idx_split:])])
        g1.recompute_bounds()
        g2.recompute_bounds()
        return [g1, g2]

    return [glyph]
