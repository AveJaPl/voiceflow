#!/usr/bin/env bash
# Fast, display-free checks for the standalone GTK application.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

mapfile -d '' python_files < <(
    find "${PROJECT_ROOT}/app" "${PROJECT_ROOT}/scripts" \
        -type f -name '*.py' -print0
)
python3 -m py_compile "${python_files[@]}"

PYTHONPATH="${PROJECT_ROOT}/app" python3 - <<'PY'
from voiceflow_app.statlib import compact_number

expected = {
    1: "1",
    999: "999",
    1_000: "1 k",
    1_618: "1,6 k",
    12_345: "12,3 k",
    # Three-digit thousands omit decimals to retain at most three digits.
    999_499: "999 k",
    # Values from 999,500 enter the millions band after rounding.
    999_500: "1 mln",
    999_999: "1 mln",
    2_400_000: "2,4 mln",
}
for value, result in expected.items():
    assert compact_number(value) == result, (value, compact_number(value), result)
PY

echo "Aplikacja: py_compile i compact_number OK"
