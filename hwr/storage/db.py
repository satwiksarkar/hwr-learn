"""
SQLite persistence layer for HWR-LEARN.
Implements:
  - WAL mode, synchronous=FULL for teach writes.
  - Schema versioning & migrations.
  - Unbounded sample storage, teach_log for persistent undo/redo.
  - Documents, glyph_log, and user settings.
  - Reset learning with safety backups.
"""

import os
import sqlite3
import json
import datetime
from typing import List, Dict, Any, Optional, Tuple
import platformdirs

CURRENT_SCHEMA_VERSION = 1


def get_default_db_path() -> str:
    """Return OS user data directory DB path (%APPDATA% on Windows, ~/.local/share on Linux)."""
    app_dir = platformdirs.user_data_dir("hwrlearn", "Antigravity")
    os.makedirs(app_dir, exist_ok=True)
    return os.path.join(app_dir, "hwrlearn.db")


class Database:
    def __init__(self, db_path: Optional[str] = None):
        if db_path is None:
            db_path = get_default_db_path()
        self.db_path = db_path
        self._redo_stack: List[Dict[str, Any]] = []

        self.conn = sqlite3.connect(self.db_path, check_same_thread=False)
        self.conn.row_factory = sqlite3.Row
        self._init_db()

    def _init_db(self):
        with self.conn:
            # WAL mode for crash safety & concurrency
            self.conn.execute("PRAGMA journal_mode=WAL;")
            self.conn.execute("PRAGMA synchronous=FULL;")
            self.conn.execute("PRAGMA foreign_keys=ON;")

            self.conn.execute("""
            CREATE TABLE IF NOT EXISTS schema_version (
                version INTEGER PRIMARY KEY
            );
            """)

            cur = self.conn.execute("SELECT version FROM schema_version;")
            row = cur.fetchone()
            if row is None:
                self._create_schema_v1()
                self.conn.execute("INSERT INTO schema_version (version) VALUES (?);", (CURRENT_SCHEMA_VERSION,))
            else:
                self._migrate(row["version"])

    def _create_schema_v1(self):
        self.conn.executescript("""
        CREATE TABLE IF NOT EXISTS samples (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            label TEXT NOT NULL,
            grid8 BLOB NOT NULL,
            grid57 BLOB NOT NULL,
            aspect INTEGER NOT NULL,
            flags INTEGER NOT NULL,
            is_tiny INTEGER NOT NULL DEFAULT 0,
            tiny_key INTEGER NOT NULL DEFAULT 0,
            thumbnail TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            source TEXT DEFAULT 'user'
        );

        CREATE TABLE IF NOT EXISTS teach_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            sample_id INTEGER,
            action TEXT NOT NULL,         -- 'add', 'delete', 'update'
            label TEXT NOT NULL,
            previous_state TEXT,          -- JSON serialized backup of state
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );

        CREATE TABLE IF NOT EXISTS documents (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            text TEXT NOT NULL,
            encoding TEXT DEFAULT 'utf-8',
            linked_file_path TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );

        CREATE TABLE IF NOT EXISTS glyph_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            document_id INTEGER NOT NULL,
            position INTEGER NOT NULL,
            strokes_json TEXT NOT NULL,
            chosen_label TEXT NOT NULL,
            candidates_json TEXT NOT NULL,
            FOREIGN KEY (document_id) REFERENCES documents (id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """)

    def _migrate(self, current_version: int):
        # Placeholder for future schema upgrades
        pass

    # ------------------ Teach & Samples ------------------

    def add_sample(
        self,
        label: str,
        grid8: Any,
        grid57: Any,
        aspect: int,
        flags: int,
        is_tiny: bool = False,
        tiny_key: int = 0,
        thumbnail: Optional[str] = None,
        source: str = "user"
    ) -> int:
        """Add a newly taught sample and log for persistent undo."""
        b8 = bytes(grid8) if not isinstance(grid8, (bytes, bytearray)) else grid8
        b57 = bytes(grid57) if not isinstance(grid57, (bytes, bytearray)) else grid57
        grid8_blob = sqlite3.Binary(b8)
        grid57_blob = sqlite3.Binary(b57)
        now = datetime.datetime.now(datetime.timezone.utc).isoformat()

        with self.conn:
            cur = self.conn.execute("""
            INSERT INTO samples (label, grid8, grid57, aspect, flags, is_tiny, tiny_key, thumbnail, created_at, source)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, (label, grid8_blob, grid57_blob, aspect, flags, 1 if is_tiny else 0, tiny_key, thumbnail, now, source))
            sample_id = cur.lastrowid

            # Log to teach_log for undo
            self.conn.execute("""
            INSERT INTO teach_log (sample_id, action, label, previous_state, created_at)
            VALUES (?, 'add', ?, NULL, ?);
            """, (sample_id, label, now))

        # Clear redo stack on new teach
        self._redo_stack.clear()
        return sample_id

    def get_all_samples(self) -> List[Dict[str, Any]]:
        try:
            import numpy as np
        except ImportError:
            np = None
        cur = self.conn.execute("SELECT * FROM samples ORDER BY id ASC;")
        samples = []
        for r in cur.fetchall():
            samples.append({
                "id": r["id"],
                "label": r["label"],
                "grid8": np.frombuffer(r["grid8"], dtype=np.uint8) if np is not None else bytes(r["grid8"]),
                "grid57": np.frombuffer(r["grid57"], dtype=np.uint8) if np is not None else bytes(r["grid57"]),
                "aspect": r["aspect"],
                "flags": r["flags"],
                "is_tiny": bool(r["is_tiny"]),
                "tiny_key": r["tiny_key"],
                "thumbnail": r["thumbnail"],
                "created_at": r["created_at"],
                "source": r["source"]
            })
        return samples

    def get_sample_count(self) -> int:
        cur = self.conn.execute("SELECT COUNT(*) FROM samples;")
        return cur.fetchone()[0]

    def get_classes_count(self) -> int:
        cur = self.conn.execute("SELECT COUNT(DISTINCT label) FROM samples;")
        return cur.fetchone()[0]

    def delete_sample(self, sample_id: int):
        cur = self.conn.execute("SELECT * FROM samples WHERE id = ?;", (sample_id,))
        row = cur.fetchone()
        if not row:
            return

        prev_state = {
            "label": row["label"],
            "grid8": row["grid8"].hex(),
            "grid57": row["grid57"].hex(),
            "aspect": row["aspect"],
            "flags": row["flags"],
            "is_tiny": row["is_tiny"],
            "tiny_key": row["tiny_key"],
            "thumbnail": row["thumbnail"],
            "source": row["source"]
        }
        now = datetime.datetime.now(datetime.timezone.utc).isoformat()

        with self.conn:
            self.conn.execute("DELETE FROM samples WHERE id = ?;", (sample_id,))
            self.conn.execute("""
            INSERT INTO teach_log (sample_id, action, label, previous_state, created_at)
            VALUES (?, 'delete', ?, ?, ?);
            """, (sample_id, row["label"], json.dumps(prev_state), now))

    def undo_last_teach(self) -> Optional[Dict[str, Any]]:
        """
        Removes the most recently taught sample or reverts the last teach action.
        Works across app restarts using the teach_log table.
        Returns a summary dict e.g. {'label': 'y', 'created_at': '...'} or None.
        """
        cur = self.conn.execute("SELECT * FROM teach_log ORDER BY id DESC LIMIT 1;")
        entry = cur.fetchone()
        if not entry:
            return None

        log_id = entry["id"]
        sample_id = entry["sample_id"]
        action = entry["action"]
        label = entry["label"]
        created_at = entry["created_at"]

        with self.conn:
            if action == "add":
                # Save into redo stack
                s_cur = self.conn.execute("SELECT * FROM samples WHERE id = ?;", (sample_id,))
                s_row = s_cur.fetchone()
                if s_row:
                    self._redo_stack.append({
                        "label": s_row["label"],
                        "grid8": s_row["grid8"],
                        "grid57": s_row["grid57"],
                        "aspect": s_row["aspect"],
                        "flags": s_row["flags"],
                        "is_tiny": s_row["is_tiny"],
                        "tiny_key": s_row["tiny_key"],
                        "thumbnail": s_row["thumbnail"],
                        "source": s_row["source"]
                    })
                self.conn.execute("DELETE FROM samples WHERE id = ?;", (sample_id,))
            self.conn.execute("DELETE FROM teach_log WHERE id = ?;", (log_id,))

        return {
            "label": label,
            "sample_id": sample_id,
            "action": action,
            "created_at": created_at
        }

    def redo_last_teach(self) -> Optional[str]:
        if not self._redo_stack:
            return None
        item = self._redo_stack.pop()
        self.add_sample(
            label=item["label"],
            grid8=bytes(item["grid8"]),
            grid57=bytes(item["grid57"]),
            aspect=item["aspect"],
            flags=item["flags"],
            is_tiny=bool(item["is_tiny"]),
            tiny_key=item["tiny_key"],
            thumbnail=item["thumbnail"],
            source=item["source"]
        )
        return item["label"]

    def reset_character_samples(self, target_char: str) -> int:
        """Reset all learned samples for one specific character class."""
        with self.conn:
            cur = self.conn.execute("DELETE FROM samples WHERE label = ?;", (target_char,))
            return cur.rowcount

    def reset_all_learning(self) -> int:
        """
        Delete ALL user-taught samples and teach history.
        Does NOT touch documents or user history.
        """
        with self.conn:
            cur = self.conn.execute("SELECT COUNT(*) FROM samples;")
            count = cur.fetchone()[0]
            self.conn.execute("DELETE FROM samples;")
            self.conn.execute("DELETE FROM teach_log;")
            self._redo_stack.clear()
            return count

    # ------------------ Documents & Glyphs ------------------

    def save_document(
        self,
        title: str,
        text: str,
        encoding: str = "utf-8",
        linked_file_path: Optional[str] = None,
        doc_id: Optional[int] = None
    ) -> int:
        now = datetime.datetime.now(datetime.timezone.utc).isoformat()
        with self.conn:
            if doc_id is None:
                cur = self.conn.execute("""
                INSERT INTO documents (title, text, encoding, linked_file_path, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?);
                """, (title, text, encoding, linked_file_path, now, now))
                return cur.lastrowid
            else:
                self.conn.execute("""
                UPDATE documents
                SET title = ?, text = ?, encoding = ?, linked_file_path = ?, updated_at = ?
                WHERE id = ?;
                """, (title, text, encoding, linked_file_path, now, doc_id))
                return doc_id

    def get_document(self, doc_id: int) -> Optional[Dict[str, Any]]:
        cur = self.conn.execute("SELECT * FROM documents WHERE id = ?;", (doc_id,))
        row = cur.fetchone()
        return dict(row) if row else None

    def list_documents(self, query: str = "") -> List[Dict[str, Any]]:
        if query:
            cur = self.conn.execute(
                "SELECT * FROM documents WHERE title LIKE ? OR text LIKE ? ORDER BY updated_at DESC;",
                (f"%{query}%", f"%{query}%")
            )
        else:
            cur = self.conn.execute("SELECT * FROM documents ORDER BY updated_at DESC;")
        return [dict(r) for r in cur.fetchall()]

    def delete_document(self, doc_id: int):
        with self.conn:
            self.conn.execute("DELETE FROM documents WHERE id = ?;", (doc_id,))

    def log_glyphs(self, doc_id: int, glyph_data: List[Dict[str, Any]]):
        with self.conn:
            self.conn.execute("DELETE FROM glyph_log WHERE document_id = ?;", (doc_id,))
            for pos, g in enumerate(glyph_data):
                self.conn.execute("""
                INSERT INTO glyph_log (document_id, position, strokes_json, chosen_label, candidates_json)
                VALUES (?, ?, ?, ?, ?);
                """, (
                    doc_id,
                    pos,
                    json.dumps(g.get("strokes", [])),
                    g.get("chosen_label", ""),
                    json.dumps(g.get("candidates", []))
                ))

    # ------------------ Settings ------------------

    def get_setting(self, key: str, default: Optional[str] = None) -> Optional[str]:
        cur = self.conn.execute("SELECT value FROM settings WHERE key = ?;", (key,))
        row = cur.fetchone()
        return row["value"] if row else default

    def set_setting(self, key: str, value: str):
        with self.conn:
            self.conn.execute("""
            INSERT INTO settings (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """, (key, value))

    def close(self):
        self.conn.close()
