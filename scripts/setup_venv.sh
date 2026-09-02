#!/usr/bin/env bash
# Create .venv and install SCAT (PyPI name: signalcat).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
python3 -m venv .venv
.venv/bin/pip install -U pip
.venv/bin/pip install -r requirements.txt
.venv/bin/pip install -e .
echo "[+] venv ready: $ROOT/.venv"
echo "    python -m nasrrc --help"
echo "    .venv/bin/python -m scat.main -V"
