#!/usr/bin/env bash
# One-command Linux packaging script for HWR-LEARN using PyInstaller.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

echo "=== Building Standalone Linux Executable for HWR-LEARN ==="

# 1. Ensure assets extracted
if [ ! -f "hwr/data/hwr_seeds_weights.npz" ]; then
    echo "Extracting model assets..."
    python3 scripts/extract_assets.py
fi

# 2. Compile native Linux driver
echo "Compiling native Linux driver..."
make -C driver clean && make -C driver all

# 3. PyInstaller build
python3 -m PyInstaller \
    --name=HWR-LEARN \
    --onedir \
    --windowed \
    --clean \
    --noconfirm \
    --add-data="hwr/data:hwr/data" \
    --add-data="driver:driver" \
    main.py

echo "Build successful! Executable is located at dist/HWR-LEARN/HWR-LEARN"
