"""
Unit tests for safe text file operations, encoding detection, atomic append, and backups.
"""

import os
import stat
import tempfile
import pytest
from hwr.file_ops.text_file import (
    detect_file_encoding_and_newline,
    LinkedTextFile,
    save_text_file,
    FileOperationError
)


def test_detect_encodings():
    """Verify detection of UTF-8, UTF-16 (with BOM), Windows-1252."""
    with tempfile.TemporaryDirectory() as tmpdir:
        # 1. UTF-8 with LF
        p_utf8 = os.path.join(tmpdir, "test_utf8.txt")
        with open(p_utf8, "wb") as f:
            f.write("Hello world\nSecond line\n".encode("utf-8"))
        content, enc, nl = detect_file_encoding_and_newline(p_utf8)
        assert enc == "utf-8"
        assert nl == "\n"
        assert "Hello world" in content

        # 2. UTF-16-LE with BOM and CRLF
        p_utf16 = os.path.join(tmpdir, "test_utf16.txt")
        with open(p_utf16, "wb") as f:
            f.write(b"\xff\xfe" + "Hello UTF16\r\nLine 2\r\n".encode("utf-16-le"))
        content16, enc16, nl16 = detect_file_encoding_and_newline(p_utf16)
        assert "utf-16" in enc16
        assert nl16 == "\r\n"
        assert "Hello UTF16" in content16

        # 3. Windows-1252 with special currency symbol (€ is 0x80 in windows-1252, invalid in utf-8)
        p_1252 = os.path.join(tmpdir, "test_1252.txt")
        with open(p_1252, "wb") as f:
            f.write(b"Price: \x80 100\r\n")
        content1252, enc1252, nl1252 = detect_file_encoding_and_newline(p_1252)
        assert enc1252 == "windows-1252"
        assert nl1252 == "\r\n"
        assert "Price:" in content1252


def test_atomic_append_and_backup():
    """
    Verify safe append:
      - .bak file created on first append of session
      - original encoding and line endings preserved
      - newline separator inserted only if missing
    """
    with tempfile.TemporaryDirectory() as tmpdir:
        file_path = os.path.join(tmpdir, "notes.txt")
        # Create file without trailing newline in CRLF format
        initial_text = "Line 1\r\nLine 2"
        with open(file_path, "wb") as f:
            f.write(initial_text.encode("utf-8"))

        linked = LinkedTextFile(file_path)
        assert not linked.has_created_session_bak

        # Append new recognized text
        appended = linked.append_text("Line 3\nLine 4")
        assert linked.has_created_session_bak

        # Verify .bak exists and matches original content
        bak_path = file_path + ".bak"
        assert os.path.exists(bak_path)
        with open(bak_path, "rb") as f:
            assert f.read() == initial_text.encode("utf-8")

        # Verify file content
        with open(file_path, "rb") as f:
            raw_data = f.read()
            expected = b"Line 1\r\nLine 2\r\nLine 3\r\nLine 4"
            assert raw_data == expected, f"Expected {expected}, got {raw_data}"


def test_external_modification_detection():
    """Verify warning when file is modified externally."""
    with tempfile.TemporaryDirectory() as tmpdir:
        file_path = os.path.join(tmpdir, "shared.txt")
        with open(file_path, "w", encoding="utf-8") as f:
            f.write("Original content\n")

        linked = LinkedTextFile(file_path)
        assert not linked.check_modified_externally()

        # External change
        with open(file_path, "a", encoding="utf-8") as f:
            f.write("Modified by another process!\n")

        assert linked.check_modified_externally()

        # Append should raise FileOperationError unless ignore flag is True
        with pytest.raises(FileOperationError, match="modified by another program"):
            linked.append_text("New handwritten text")


def test_read_only_handling():
    """Verify clear error message on read-only file."""
    with tempfile.TemporaryDirectory() as tmpdir:
        file_path = os.path.join(tmpdir, "readonly.txt")
        with open(file_path, "w", encoding="utf-8") as f:
            f.write("Read-only text\n")

        # Make file read-only
        os.chmod(file_path, stat.S_IREAD)

        linked = LinkedTextFile(file_path)
        writable, reason = linked.is_writable()
        assert not writable
        assert "read-only" in reason.lower()

        with pytest.raises(FileOperationError, match="read-only"):
            linked.append_text("Try to append")

        # Restore write permissions for cleanup
        os.chmod(file_path, stat.S_IWRITE)
