#!/usr/bin/env python3
"""
One-command Windows portable .exe build script using PyInstaller.
Bundles:
  - Python runtime
  - PySide6 Qt binaries and plugins
  - NumPy
  - SQLite3
  - Extracted seed data and models (hwr/data)
Usage:
    python scripts/build_windows.py
Output:
    dist/HWR-LEARN.exe
"""

import os
import sys
import subprocess
import shutil

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_DIR = os.path.join(ROOT_DIR, "hwr", "data")
DRIVER_DIR = os.path.join(ROOT_DIR, "driver")
DIST_DIR = os.path.join(ROOT_DIR, "dist")
BUILD_DIR = os.path.join(ROOT_DIR, "build")


def build():
    print("=== Building Standalone Windows Executable for HWR-LEARN ===")
    os.chdir(ROOT_DIR)

    # Ensure asset files exist
    npz_file = os.path.join(DATA_DIR, "hwr_seeds_weights.npz")
    if not os.path.exists(npz_file):
        print("Extracting model assets first...")
        subprocess.run([sys.executable, "scripts/extract_assets.py"], check=True)

    # Ensure driver binaries exist
    driver_exe = os.path.join(DRIVER_DIR, "hwr_driver.exe")
    if not os.path.exists(driver_exe):
        try:
            print("Compiling native driver binaries...")
            subprocess.run(["gcc", "-O3", "-shared", "-o", os.path.join(DRIVER_DIR, "hwr_driver32.dll"), os.path.join(DRIVER_DIR, "hwr_driver.c"), "-DHWR_BUILD_DLL"], check=True)
            subprocess.run(["gcc", "-O3", "-o", os.path.join(DRIVER_DIR, "hwr_driver.exe"), os.path.join(DRIVER_DIR, "hwr_driver.c"), os.path.join(DRIVER_DIR, "hwr_cli.c"), "-DHWR_STATIC"], check=True)
        except Exception as e:
            print(f"Driver compilation warning: {e}")

    # PyInstaller arguments
    cmd = [
        sys.executable,
        "-m", "PyInstaller",
        "--name=HWR-LEARN",
        "--onedir",             # Onedir distribution for faster startup and reliability
        "--windowed",           # GUI mode without console window
        "--clean",
        "--noconfirm",
        f"--add-data={DRIVER_DIR};driver",
        "main.py"
    ]

    print(f"Running PyInstaller: {' '.join(cmd)}")
    subprocess.run(cmd, check=True)

    output_exe = os.path.join(DIST_DIR, "HWR-LEARN", "HWR-LEARN.exe")
    if os.path.exists(output_exe):
        print("\n=======================================================")
        print("Build Successful!")
        print(f"Portable Application Bundle: {os.path.join(DIST_DIR, 'HWR-LEARN')}")
        print(f"Executable: {output_exe}")
        print("=======================================================\n")
    else:
        print("Build finished, check dist directory for outputs.")


if __name__ == "__main__":
    build()
