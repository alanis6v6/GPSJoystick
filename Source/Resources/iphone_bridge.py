"""Run one iPhone developer location session over a private stdin/stdout pipe."""

import asyncio
from contextlib import AsyncExitStack
import json
import math
import sys


class BridgeError(Exception):
    pass


def emit(event, **fields):
    print(json.dumps({"event": event, **fields}, ensure_ascii=True), flush=True)


async def usb_devices(usbmux):
    return [device for device in await usbmux.list_devices() if device.is_usb]


def coordinates(command):
    latitude = float(command["latitude"])
    longitude = float(command["longitude"])
    if not (
        math.isfinite(latitude) and math.isfinite(longitude)
        and -90 <= latitude <= 90 and -180 <= longitude <= 180
    ):
        raise BridgeError("經緯度超出範圍。")
    return latitude, longitude


async def serve(location, usbmux, serial, reader):
    may_be_simulated = False
    try:
        while True:
            try:
                line = await asyncio.wait_for(reader.readline(), timeout=1.5)
            except asyncio.TimeoutError:
                devices = await asyncio.wait_for(usb_devices(usbmux), timeout=3)
                if not any(device.serial == serial for device in devices):
                    raise BridgeError("iPhone 的 USB 連線已中斷。")
                continue

            if not line:
                break
            command = json.loads(line)
            action = command.get("action")
            if action == "set":
                latitude, longitude = coordinates(command)
                may_be_simulated = True
                await asyncio.wait_for(location.set(latitude, longitude), timeout=3)
                emit("set")
            elif action == "clear":
                await asyncio.wait_for(location.clear(), timeout=3)
                may_be_simulated = False
                emit("cleared")
            elif action == "disconnect":
                break
            else:
                raise BridgeError("無法辨識定位指令。")
    finally:
        if may_be_simulated:
            await asyncio.wait_for(location.clear(), timeout=3)
            emit("cleared")


async def main():
    try:
        from pymobiledevice3 import usbmux
        from pymobiledevice3.lockdown import create_using_usbmux
        from pymobiledevice3.remote.rsd_tunnel import PreferredRsdTunnel
        from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
        from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation
    except ImportError as error:
        raise BridgeError("iPhone 連線元件未安裝完整。請執行 Setup-iPhone.command。") from error

    devices = await asyncio.wait_for(usb_devices(usbmux), timeout=5)
    if not devices:
        raise BridgeError("找不到 USB iPhone。請用可傳輸資料的線接上 iPhone 並解鎖。")
    if len(devices) != 1:
        raise BridgeError("偵測到多台 USB 裝置。請只接上這次要測試的 iPhone。")
    serial = devices[0].serial
    if len(sys.argv) > 1 and serial != sys.argv[1]:
        raise BridgeError("請重新接上前一次模擬定位的 iPhone，再恢復定位。")

    lockdown = await asyncio.wait_for(
        create_using_usbmux(serial=serial, connection_type="USB", autopair=False), timeout=7
    )
    async with lockdown:
        if not lockdown.paired:
            raise BridgeError("iPhone 尚未配對。請在 Finder 選取 iPhone，並在手機上點選「信任」。")
        info = lockdown.short_info
        if info.get("DeviceClass") not in (None, "iPhone"):
            raise BridgeError("請接上要測試的 iPhone。")
        version = lockdown.product_version
        if int(str(version).split(".")[0]) < 17:
            raise BridgeError("這個原型使用 iOS 17 以上的開發者連線。")
        label = f"{info.get('DeviceName') or 'iPhone'} · iOS {version}"

    reader = asyncio.StreamReader()
    pipe, _ = await asyncio.get_running_loop().connect_read_pipe(
        lambda: asyncio.StreamReaderProtocol(reader), sys.stdin.buffer
    )
    try:
        async with AsyncExitStack() as stack:
            tunnel = PreferredRsdTunnel(serial=serial, autopair=False)
            rsd = await asyncio.wait_for(stack.enter_async_context(tunnel), timeout=15)
            dvt = await asyncio.wait_for(stack.enter_async_context(DvtProvider(rsd)), timeout=6)
            location = await asyncio.wait_for(
                stack.enter_async_context(LocationSimulation(dvt)), timeout=6
            )
            emit("ready", label=label, serial=serial)
            await serve(location, usbmux, serial, reader)
    finally:
        pipe.close()
    emit("closed")


def main_error(error):
    if isinstance(error, BridgeError):
        return str(error)
    if isinstance(error, asyncio.TimeoutError):
        return "iPhone 開發者服務逾時。請解鎖 iPhone、確認開發者模式，然後重接 USB。"
    kind = type(error).__name__
    if "Password" in kind or "Locked" in kind:
        return "請先解鎖 iPhone，再重新連線。"
    if "Pair" in kind:
        return "無法驗證 iPhone 配對。請在 Finder 確認 iPhone 已信任這台 Mac。"
    detail = " ".join(str(error).split())[:200]
    return f"iPhone 開發者服務連線失敗。請確認手機已解鎖並開啟開發者模式。\n{kind}: {detail}"


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except Exception as error:
        emit("error", message=main_error(error))
        sys.exit(1)
