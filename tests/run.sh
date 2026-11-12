#!/usr/bin/env bash
# Runs tests/tst_setup.qml offscreen against Omarchy's own shell kit (qs.Ui, qs.Commons)
# and the omaddons repository's Quickshell stand-ins, which let a test answer each
# process the button starts. Nothing real runs: no omaddons, no mise, no shell.
#
# Usage: tests/run.sh [path to an omaddons checkout]   (default: ../omaddons)
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
omaddons=${1:-$here/../omaddons}
kit=${OMARCHY_SHELL_DIR:-/usr/share/omarchy/shell}
stubs=$omaddons/omarchy/tests/qml/imports
overlay=$omaddons/omarchy/tests/qml/kit/Quickshell
runner=""
for candidate in /usr/lib/qt6/bin/qmltestrunner qmltestrunner6 qmltestrunner-qt6; do
    if command -v "$candidate" >/dev/null; then runner=$candidate; break; fi
done

[[ -n $runner ]] || { echo "run.sh: Qt 6's qmltestrunner is missing (qt6-declarative)" >&2; exit 2; }
[[ -f $kit/Ui/qmldir ]] || { echo "run.sh: no Omarchy shell kit at $kit" >&2; exit 2; }
[[ -d $stubs ]] || { echo "run.sh: no omaddons checkout at $omaddons (pass its path)" >&2; exit 2; }

tree=$(mktemp -d)
trap 'rm -rf -- "$tree"' EXIT
mkdir -p "$tree/qs"
cp -r "$kit/Ui" "$tree/qs/Ui"
# The layer-shell parts can't open offscreen: the stand-ins draw them in the test window.
cp "$stubs/qs/Ui/KeyboardPanel.qml" "$stubs/qs/Ui/Panel.qml" "$tree/qs/Ui/"
cp -r "$kit/Commons" "$tree/qs/Commons"
grep -v -E '^(singleton )?(AudioNodes|InputDevices|InputMethodState|UntypedInput) ' \
    "$kit/Commons/qmldir" >"$tree/qs/Commons/qmldir"
cp -r "$stubs/Quickshell" "$tree/Quickshell"
cp -r "$overlay/." "$tree/Quickshell/"
printf 'Singleton 1.0 Singleton.qml\n' >>"$tree/Quickshell/qmldir"
printf 'FileView 1.0 FileView.qml\n' >>"$tree/Quickshell/Io/qmldir"
printf '.pragma library\nvar ENV = {"HOME": ""}\n' >"$tree/Quickshell/KitEnv.js"

cd "$here"
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software QML_XHR_ALLOW_FILE_READ=1 \
    "$runner" -input tests/tst_setup.qml -import "$tree" -o -,txt
