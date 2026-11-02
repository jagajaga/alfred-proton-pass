#!/bin/bash
# Run the whole test suite: bash tests for index.sh, unittest for filter.py.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
rc=0
"$HERE/test_index.sh" || rc=1
python3 -m unittest discover -s "$HERE" -p 'test_*.py' -v || rc=1
exit $rc
