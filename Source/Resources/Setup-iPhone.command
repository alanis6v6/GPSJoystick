#!/bin/bash
set -euo pipefail

support_dir="$HOME/Library/Application Support/GPSJoystick"
python_dir="$support_dir/python"
ready_file="$support_dir/iphone-support-ready"
base_python="${GPS_JOYSTICK_PYTHON:-/usr/bin/python3}"

printf 'GPS 搖桿 — 安裝 iPhone 連線元件\n\n'

if ! "$base_python" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)'; then
    printf '請先安裝支援的 Python 3.9 以上版本，或在終端機用 GPS_JOYSTICK_PYTHON 指定 Python 路徑。\n'
    exit 1
fi

/bin/mkdir -p "$support_dir"
install_lock="$support_dir/installing"
if ! /bin/mkdir "$install_lock" 2>/dev/null; then
    printf '另一個安裝程序正在執行。請等它結束後再試。\n'
    exit 1
fi
trap '/bin/rmdir "$install_lock"' EXIT
/bin/rm -f "$ready_file"

"$base_python" -m venv "$python_dir"
"$python_dir/bin/python3" -I -m pip --disable-pip-version-check install "pymobiledevice3==11.55.0"
"$python_dir/bin/python3" -I -c '
from pymobiledevice3 import usbmux
from pymobiledevice3.remote.rsd_tunnel import PreferredRsdTunnel
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation
'
/usr/bin/touch "$ready_file"

printf '\n安裝完成。回到 GPS 搖桿，按「連接 iPhone」。\n'
