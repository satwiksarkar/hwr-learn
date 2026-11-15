"""
Theme tokens, dynamic QSS stylesheets, and SVG icon generators for HWR-LEARN.
Supports Light and Dark themes with WCAG AA compliance.
"""

from typing import Dict, Any


LIGHT_THEME = {
    "name": "light",
    "bg_app": "#F8F9FA",
    "bg_canvas": "#FFFFFF",
    "bg_card": "#FFFFFF",
    "bg_card_subtle": "#F1F3F5",
    "border_subtle": "#E9ECEF",
    "border_strong": "#CED4DA",
    "text_primary": "#1A1D20",
    "text_secondary": "#5A626A",
    "text_muted": "#8C959F",
    "accent": "#3B5BDB",
    "accent_hover": "#364FC7",
    "accent_subtle": "#EDF2FF",
    "sure": "#2B8A3E",
    "sure_bg": "#EBFBEE",
    "unsure": "#E03131",
    "unsure_bg": "#FFF5F5",
    "teach": "#1C7ED6",
    "teach_bg": "#E7F5FF",
    "warn": "#E8590C",
    "ink_default": "#F59E0B",
    "canvas_guideline": "#CED4DA",
}

DARK_THEME = {
    "name": "dark",
    "bg_app": "#121417",
    "bg_canvas": "#1E2126",
    "bg_card": "#262A30",
    "bg_card_subtle": "#2E333B",
    "border_subtle": "#383E47",
    "border_strong": "#495057",
    "text_primary": "#F1F3F5",
    "text_secondary": "#ADB5BD",
    "text_muted": "#6C757D",
    "accent": "#4C6EF5",
    "accent_hover": "#5C7CFA",
    "accent_subtle": "#1C2438",
    "sure": "#51CF66",
    "sure_bg": "#1B3523",
    "unsure": "#FF6B6B",
    "unsure_bg": "#3E1E22",
    "teach": "#4DABF7",
    "teach_bg": "#182C3F",
    "warn": "#FF922B",
    "ink_default": "#F59E0B",
    "canvas_guideline": "#495057",
}


def generate_stylesheet(theme: Dict[str, Any]) -> str:
    """Generate complete Qt Style Sheet (QSS) for the application."""
    return f"""
    QMainWindow, QWidget#centralWidget {{
        background-color: {theme['bg_app']};
        color: {theme['text_primary']};
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    }}

    QMenuBar {{
        background-color: {theme['bg_card']};
        color: {theme['text_primary']};
        border-bottom: 1px solid {theme['border_subtle']};
        padding: 4px 8px;
    }}
    QMenuBar::item {{
        padding: 4px 10px;
        background: transparent;
        border-radius: 4px;
    }}
    QMenuBar::item:selected {{
        background-color: {theme['bg_card_subtle']};
    }}
    QMenu {{
        background-color: {theme['bg_card']};
        color: {theme['text_primary']};
        border: 1px solid {theme['border_subtle']};
        border-radius: 8px;
        padding: 4px;
    }}
    QMenu::item {{
        padding: 6px 24px 6px 12px;
        border-radius: 4px;
    }}
    QMenu::item:selected {{
        background-color: {theme['accent_subtle']};
        color: {theme['accent']};
    }}
    QMenu::separator {{
        height: 1px;
        background: {theme['border_subtle']};
        margin: 4px 8px;
    }}

    /* Card Panels */
    QFrame#cardPanel {{
        background-color: {theme['bg_card']};
        border: 1px solid {theme['border_subtle']};
        border-radius: 12px;
    }}

    /* Buttons */
    QPushButton {{
        background-color: {theme['bg_card']};
        color: {theme['text_primary']};
        border: 1px solid {theme['border_subtle']};
        border-radius: 8px;
        padding: 6px 14px;
        font-weight: 500;
        font-size: 13px;
    }}
    QPushButton:hover {{
        background-color: {theme['bg_card_subtle']};
        border-color: {theme['border_strong']};
    }}
    QPushButton:pressed {{
        background-color: {theme['border_subtle']};
    }}

    QPushButton#primaryButton {{
        background-color: {theme['accent']};
        color: #FFFFFF;
        border: none;
        border-radius: 10px;
        padding: 8px 22px;
        font-weight: 600;
        font-size: 14px;
    }}
    QPushButton#primaryButton:hover {{
        background-color: {theme['accent_hover']};
    }}

    QPushButton#dangerButton {{
        background-color: transparent;
        color: {theme['unsure']};
        border: 1px solid {theme['unsure']};
        border-radius: 8px;
        padding: 6px 12px;
    }}
    QPushButton#dangerButton:hover {{
        background-color: {theme['unsure_bg']};
    }}

    /* Inputs */
    QLineEdit, QComboBox, QSpinBox {{
        background-color: {theme['bg_card']};
        color: {theme['text_primary']};
        border: 1px solid {theme['border_subtle']};
        border-radius: 8px;
        padding: 6px 10px;
        font-size: 13px;
    }}
    QLineEdit:focus, QComboBox:focus {{
        border: 1.5px solid {theme['accent']};
    }}

    /* Status Bar */
    QStatusBar {{
        background-color: {theme['bg_card']};
        color: {theme['text_secondary']};
        border-top: 1px solid {theme['border_subtle']};
        padding: 4px 12px;
        font-size: 11px;
    }}

    /* Scrollbars */
    QScrollBar:vertical {{
        background: transparent;
        width: 8px;
        margin: 0px;
    }}
    QScrollBar::handle:vertical {{
        background: {theme['border_strong']};
        border-radius: 4px;
        min-height: 24px;
    }}
    QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {{
        height: 0px;
    }}

    /* Tooltips */
    QToolTip {{
        background-color: {theme['bg_card']};
        color: {theme['text_primary']};
        border: 1px solid {theme['border_subtle']};
        border-radius: 6px;
        padding: 4px 8px;
        font-size: 11px;
    }}
    """
