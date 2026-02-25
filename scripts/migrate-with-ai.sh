#!/usr/bin/env bash
set -e

pip install requests pyyaml

python scripts/migrate.py
python scripts/summary_generator.py