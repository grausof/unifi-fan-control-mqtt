#!/bin/bash
###############################################################################
# Syntax check — bash -n on all shell scripts
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "  Checking fan-control.sh ..."
bash -n "$REPO_ROOT/fan-control.sh"

echo "  Checking mqtt-control.sh ..."
bash -n "$REPO_ROOT/mqtt-control.sh"

echo "  Checking install.sh ..."
bash -n "$REPO_ROOT/install.sh"

echo "  Checking uninstall.sh ..."
bash -n "$REPO_ROOT/uninstall.sh"

echo "  Checking harness.sh ..."
bash -n "$REPO_ROOT/tests/lib/harness.sh"

echo "  Checking run-tests.sh ..."
bash -n "$REPO_ROOT/tests/run-tests.sh"

echo "  All syntax checks passed."
