# HWR-LEARN — Handwriting OCR that Learns from You

A complete, modern, offline, cross-platform desktop application for handwriting recognition and continuous active-learning transcription.

Re-implemented natively from the 16-bit x86 DOSBox prototype (`reference/hwr_learn_improved.asm`) with a modern digital-notebook interface, multi-model fusion, persistent SQLite storage, and safe text file operations.

---

## 1. Quick Start: How to Run It

### Option A: Run the Desktop GUI Directly
Ensure requirements are installed:
```bash
pip install -r requirements.txt
```
Launch the application:
```bash
python main.py
```

### Option B: Run the Acceptance & Unit Test Suite
To verify the core engine, algorithmic fixes, persistence, and safe file operations:
```bash
python -m pytest -v
```
All 21 acceptance, driver, storage, file operations, and UI tests will execute and report verification metrics.

### Option C: Re-Extract Assets from MASM Assembly
To re-parse and regenerate the 4,369 seeds, 134 base prototypes, and perceptron weights directly from `reference/hwr_learn_improved.asm`:
```bash
python scripts/extract_assets.py
```

### Option D: Build Standalone Executable (PyInstaller)
- **Windows**:
  ```powershell
  python scripts/build_windows.py
  ```
  Produces standalone executable at `dist/HWR-LEARN/HWR-LEARN.exe`.
- **Linux**:
  ```bash
  bash scripts/build_linux.sh
  ```
  Produces standalone executable at `dist/HWR-LEARN/HWR-LEARN`.

---

## 2. Architecture & Native Driver

HWR-LEARN features a hybrid architecture combining a high-performance native C/Assembly driver core with a modern PySide6 desktop interface:

```
┌────────────────────────────────────────────────────────┐
│                   PySide6 Desktop UI                   │
│   (Floating Paper Canvas, Top-3 Popovers, Teach View)  │
└───────────────────────────┬────────────────────────────┘
                            │
               ┌────────────┴────────────┐
               │  DriverBridge (Python)  │
               └────────────┬────────────┘
                            │
                            ▼
┌────────────────────────────────────────────────────────┐
│                  Native C Driver Core                  │
│  - driver/hwr_driver.c & driver/hwr_data.h             │
│  - 4,369 font seeds, 134 prototypes, perceptron        │
│  - Windows 32-bit DLL & high-speed IPC harness         │
│  - Linux shared object (libhwr_driver.so)              │
│  - Android NDK library via CMake                       │
└────────────────────────────────────────────────────────┘
```

- **Zero Emulation Overhead**: Completely replaces 16-bit DOSBox with native C99 execution compiled for modern CPU targets.
- **Cross-Platform Compatibility**:
  - **Windows**: Compiled with MinGW GCC (`driver/hwr_driver32.dll` and `driver/hwr_driver.exe`). Seamlessly executed via ctypes or background IPC harness.
  - **Linux & Touch Screens**: Compiled with standard GCC/Clang via `driver/Makefile` into `libhwr_driver.so`.
  - **Android Touch Devices**: Compilable via CMake/NDK (`driver/CMakeLists.txt`) for touch screen integration.
- **Self-Contained Data**: Static tables embedded directly into `driver/hwr_data.h` containing all 4,369 seeds, 134 prototypes, and perceptron matrices.

---

## 3. Key Features

- **Floating Paper Canvas**:
  - Smooth, anti-aliased pen ink with mouse, stylus, or touch support.
  - Optional writing guidelines (baseline and x-height reference at 68%).
  - Adjustable pen nib thickness and ink color.
- **Top-3 Dropdown Popover**:
  - Every recognized character is interactive and clickable.
  - Displays top 3 candidate shapes with confidence scores and progress bars.
  - Input field to teach any ASCII or Unicode symbol on the fly.
  - Immediate model reinforcement on every selection without restarts or retrain delays.
- **Persistent Online Learning**:
  - Taught samples are committed immediately to SQLite with Write-Ahead Logging (`WAL`) and `synchronous=FULL`.
  - **Undo Last Teach (`Ctrl+Shift+Z`)**: Reverts the most recently taught sample; persists across application restarts.
  - Two-step confirmed **Reset All Learning** with automatic timestamped backup retention.
- **Safe File Operations**:
  - Automatic encoding detection (UTF-8, UTF-16, Windows-1252, Latin-1 fallback).
  - Preserves original encoding and line ending style (`LF` vs `CRLF`).
  - **Safe Append Mode**: Appends newly transcribed text to the end of a linked file. Never overwrites existing bytes.
  - Creates a safety session backup (`file.txt.bak`) before the first append.
  - Detects external file modifications made by other applications before writing.

---

## 3. Keyboard Shortcuts

| Shortcut | Action |
| :--- | :--- |
| **Ctrl + Enter** | **READ** — Transcribe handwriting on canvas |
| **Ctrl + Z** | Undo last pen stroke |
| **Ctrl + Y** | Redo pen stroke |
| **Ctrl + Shift + Z** | **Undo Last Teach** (reverts previous taught sample) |
| **Ctrl + O** | Open / link an existing `.txt` file |
| **Ctrl + Shift + A** | **Append to File** (safe append to linked file) |
| **Ctrl + S** | Save As new `.txt` file |
| **Ctrl + K** | Clear drawing canvas |
| **Ctrl + C** | Copy recognized text to clipboard |
| **1 / 2 / 3** | Choose candidate 1, 2, or 3 in popover |
| **Esc** | Close dropdown popovers and modal dialogs |

---

## 4. Persistent Data Locations

User data is stored in the standard operating system application data folder via `platformdirs`:
- **Windows**: `%APPDATA%\hwrlearn\hwrlearn.db` (typically `C:\Users\<User>\AppData\Roaming\hwrlearn\hwrlearn.db`)
- **Linux**: `~/.local/share/hwrlearn/hwrlearn.db`
- **Rolling Backups**: Located in `backups/` subfolder next to the database file (e.g. `%APPDATA%\hwrlearn\backups\hwrlearn_backup_YYYYMMDD_HHMMSS.db`).

---

## 5. Acceptance Test Results (Section 9 Verification)

Emulation against the improved assembly reference and sample handwriting ("Hey how are you"):
- **Outlier Reference Robustness**: Normal-height letters are protected from being misclassified as punctuation despite tall outlier strokes.
- **Teach 8 Glyphs Once (`H, e, y, h, o, w, e, y`) & Re-read**: **8/8 correct** (100%).
- **Perturbation Test (20 runs with $\pm 11\%$ scale, slant, wobble, $\pm 3\text{ px}$ jitter)**: **96.2% accuracy** (exceeds required $\ge 90\%$).
- **Persistence Across Restart**: Verified across simulated process kills and database reloads.
- **Connected Letter Splitter**: Valley density detection accurately splits cursive ligatures ("ar", "ou").
- **Safe File Append**: Verified against UTF-8, UTF-16, and Windows-1252 files with line ending preservation and `.bak` backup creation.
