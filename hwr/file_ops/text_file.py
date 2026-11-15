"""
Safe text file operations:
  - Encoding detection (BOM check, UTF-8, UTF-16-LE/BE, Windows-1252, Latin-1).
  - Line ending preservation (CRLF vs LF).
  - Atomic and safe append with .bak backup on first append of session.
  - External modification detection (mtime & size check).
  - Read-only and file-lock safety checks with clear, user-friendly exceptions.
  - Save as with encoding and error-handling choices (replace, ignore, strict).
"""

import os
import shutil
import stat
from typing import Tuple, Optional, Dict, Any


SUPPORTED_ENCODINGS = [
    "utf-8",
    "utf-8-sig",
    "utf-16",
    "utf-16-le",
    "utf-16-be",
    "windows-1252",
    "latin-1",
    "ascii"
]


class FileOperationError(Exception):
    """User-friendly error for file operations."""
    pass


def detect_newline(content: str) -> str:
    """Detect dominant newline in text content: '\\r\\n' (CRLF) or '\\n' (LF)."""
    crlf_count = content.count("\r\n")
    lf_count = content.count("\n") - crlf_count
    return "\r\n" if crlf_count >= lf_count and crlf_count > 0 else "\n"


def detect_file_encoding_and_newline(file_path: str) -> Tuple[str, str, str]:
    """
    Detect file encoding and dominant newline style (LF vs CRLF).
    Returns (content, detected_encoding, newline_style)
    """
    if not os.path.exists(file_path):
        raise FileOperationError(f"File not found: {file_path}")

    # Read raw bytes
    try:
        with open(file_path, "rb") as f:
            raw_bytes = f.read()
    except PermissionError:
        raise FileOperationError(f"Permission denied reading file: {file_path}")
    except OSError as e:
        raise FileOperationError(f"Could not open file: {e}")

    # 1. BOM checks
    if raw_bytes.startswith(b"\xef\xbb\xbf"):
        encoding = "utf-8-sig"
        try:
            content = raw_bytes.decode("utf-8-sig")
            return content, encoding, detect_newline(content)
        except UnicodeDecodeError:
            pass

    if raw_bytes.startswith(b"\xff\xfe"):
        encoding = "utf-16-le"
        try:
            content = raw_bytes.decode("utf-16-le")
            return content, encoding, detect_newline(content)
        except UnicodeDecodeError:
            pass

    if raw_bytes.startswith(b"\xfe\xff"):
        encoding = "utf-16-be"
        try:
            content = raw_bytes.decode("utf-16-be")
            return content, encoding, detect_newline(content)
        except UnicodeDecodeError:
            pass

    # 2. Strict UTF-8 check
    try:
        content = raw_bytes.decode("utf-8")
        return content, "utf-8", detect_newline(content)
    except UnicodeDecodeError:
        pass

    # 3. Windows-1252 check
    try:
        content = raw_bytes.decode("windows-1252")
        return content, "windows-1252", detect_newline(content)
    except UnicodeDecodeError:
        pass

    # 4. Latin-1 fallback (always succeeds on arbitrary bytes)
    content = raw_bytes.decode("latin-1")
    return content, "latin-1", detect_newline(content)


class LinkedTextFile:
    def __init__(self, file_path: str, forced_encoding: Optional[str] = None):
        self.file_path = os.path.abspath(file_path)
        self.forced_encoding = forced_encoding
        self.encoding: str = forced_encoding or "utf-8"
        self.newline_style: str = "\n"
        self.last_mtime: float = 0.0
        self.last_size: int = 0
        self.has_created_session_bak: bool = False

        self.reload()

    def reload(self) -> str:
        """Reload file content and update tracking metadata."""
        content, enc, nl = detect_file_encoding_and_newline(self.file_path)
        self.encoding = self.forced_encoding if self.forced_encoding else enc
        self.newline_style = nl

        st = os.stat(self.file_path)
        self.last_mtime = st.st_mtime
        self.last_size = st.st_size
        return content

    def check_modified_externally(self) -> bool:
        """Returns True if file was changed on disk since last read/write."""
        if not os.path.exists(self.file_path):
            return True
        st = os.stat(self.file_path)
        # Check mtime or size difference
        return (abs(st.st_mtime - self.last_mtime) > 1e-4) or (st.st_size != self.last_size)

    def is_writable(self) -> Tuple[bool, str]:
        """Check if file can be written to without errors."""
        if not os.path.exists(self.file_path):
            parent = os.path.dirname(self.file_path)
            if not os.access(parent, os.W_OK):
                return False, f"Directory is not writable: {parent}"
            return True, ""

        # Check read-only attribute
        mode = os.stat(self.file_path).st_mode
        if not (mode & stat.S_IWRITE):
            return False, f"The file '{os.path.basename(self.file_path)}' is marked read-only."

        # Test write open
        try:
            with open(self.file_path, "a+b"):
                pass
        except PermissionError:
            return False, f"The file '{os.path.basename(self.file_path)}' is locked by another application."
        except OSError as e:
            return False, f"Cannot write to file: {e}"

        return True, ""

    def append_text(self, text_to_append: str, ignore_external_mod: bool = False) -> str:
        """
        Safely append text to the linked file:
          1. Checks writable permissions.
          2. Detects external modification warning.
          3. Creates a single .bak file for the session before first append.
          4. Ensures preceding newline separator if file didn't end with one.
          5. Preserves exact original encoding and newline style.
          6. Flushes and fsyncs to disk.
        """
        writable, reason = self.is_writable()
        if not writable:
            raise FileOperationError(reason)

        if not ignore_external_mod and self.check_modified_externally():
            raise FileOperationError(
                f"The file '{os.path.basename(self.file_path)}' was modified by another program since it was opened."
            )

        # Session backup (.bak) on first append
        if not self.has_created_session_bak:
            bak_path = self.file_path + ".bak"
            try:
                shutil.copy2(self.file_path, bak_path)
                self.has_created_session_bak = True
            except OSError as e:
                raise FileOperationError(f"Could not create backup file ({bak_path}): {e}")

        # Read trailing bytes to check if newline separator is needed
        with open(self.file_path, "rb") as f:
            raw_bytes = f.read()

        needs_leading_newline = False
        if len(raw_bytes) > 0:
            if not raw_bytes.endswith(b"\n") and not raw_bytes.endswith(b"\r"):
                needs_leading_newline = True

        # Standardize newlines in text_to_append to match file's newline style
        normalized = text_to_append.replace("\r\n", "\n").replace("\r", "\n")
        formatted_append = normalized.replace("\n", self.newline_style)

        if needs_leading_newline:
            formatted_append = self.newline_style + formatted_append

        # Encode bytes using the file's encoding (skip BOM on append if already present in file)
        enc_for_append = self.encoding
        if enc_for_append == "utf-8-sig":
            enc_for_append = "utf-8"  # don't insert duplicate BOM in the middle of file
        elif enc_for_append in ("utf-16", "utf-16-le"):
            enc_for_append = "utf-16-le"
        elif enc_for_append == "utf-16-be":
            enc_for_append = "utf-16-be"

        try:
            append_bytes = formatted_append.encode(enc_for_append)
        except UnicodeEncodeError as e:
            raise FileOperationError(
                f"Some characters cannot be represented in encoding '{self.encoding}': {e}"
            )

        # Atomic append write with fsync
        try:
            with open(self.file_path, "ab") as f:
                f.write(append_bytes)
                f.flush()
                os.fsync(f.fileno())
        except OSError as e:
            raise FileOperationError(f"Write error while appending to '{self.file_path}': {e}")

        # Update metadata
        st = os.stat(self.file_path)
        self.last_mtime = st.st_mtime
        self.last_size = st.st_size

        return formatted_append


def save_text_file(
    file_path: str,
    text: str,
    encoding: str = "utf-8",
    newline: str = "\n",
    errors: str = "strict"
):
    """
    Save new or existing text file with chosen encoding, newline style, and error handling.
    Atomic write via temporary file replacement.
    """
    normalized = text.replace("\r\n", "\n").replace("\r", "\n")
    formatted = normalized.replace("\n", newline)

    try:
        encoded_data = formatted.encode(encoding, errors=errors)
    except UnicodeEncodeError as e:
        raise FileOperationError(
            f"Characters in text cannot be encoded using '{encoding}': {e}. Choose replace or UTF-8."
        )

    tmp_path = file_path + ".tmp"
    try:
        with open(tmp_path, "wb") as f:
            f.write(encoded_data)
            f.flush()
            os.fsync(f.fileno())
        shutil.move(tmp_path, file_path)
    except OSError as e:
        if os.path.exists(tmp_path):
            try:
                os.remove(tmp_path)
            except OSError:
                pass
        raise FileOperationError(f"Failed to write file '{file_path}': {e}")
