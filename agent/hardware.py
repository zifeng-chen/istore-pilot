"""硬件与固件信息：给「概览 → 机器」提供明细。

数据全部来自内核 sysfs / procfs，只有 PCI 设备名需要 lspci（装了 pciutils 才有）。

为什么不能只读 DMI：软路由（尤其 N100 / 8505 这类工控板）的 DMI 常年是
`Default string`，product_name / board_name 全是占位符。只显示这些等于什么都没说。
所以要绕开它，把「真实存在、能对上型号」的东西摆出来：
BIOS 版本与日期、内存条的容量/类型/频率/厂商、NVMe 型号、网卡芯片型号、CPU 型号与缓存。
把这些拼起来，用户自己就能认出这是哪台机器。

DMI 里的内存条信息（SMBIOS Type 17）是唯一能拿到「DDR5-5600」这种细节的地方，
所以在 kernel 暴露了 /sys/firmware/dmi/entries 的情况下手写一个极小的结构解析。
"""
from __future__ import annotations

import os
import platform
import re
import time

from . import sysinfo

# SMBIOS 内存类型码 → 名称。只列常见的，其余按 Unknown 处理。
_MEM_TYPES = {
    0x03: "DRAM", 0x0C: "SDRAM", 0x0D: "SGRAM", 0x0F: "SDRAM",
    0x11: "SDRAM", 0x12: "DDR", 0x13: "DDR2", 0x14: "DDR2 FB-DIMM",
    0x18: "DDR3", 0x1A: "DDR4", 0x1B: "LPDDR", 0x1C: "LPDDR2",
    0x1D: "LPDDR3", 0x1E: "LPDDR4", 0x22: "DDR5", 0x23: "LPDDR5",
}

_FORM_FACTORS = {
    0x01: "Other", 0x02: "Unknown", 0x03: "SIMM", 0x04: "SIP",
    0x05: "Chip", 0x06: "DIP", 0x07: "ZIP", 0x08: "Proprietary Card",
    0x09: "DIMM", 0x0A: "TSOP", 0x0B: "Row of chips", 0x0C: "RIMM",
    0x0D: "SODIMM", 0x0E: "SRIMM", 0x0F: "FB-DIMM",
}

_CHASSIS = {
    0x03: "台式机", 0x04: "低平台", 0x05: "披萨盒", 0x06: "迷你机箱",
    0x07: "塔式", 0x08: "便携", 0x09: "笔记本", 0x0A: "Notebook",
    0x0B: "手持", 0x0C: "Docking", 0x0D: "一体机", 0x0E: "子笔记本",
    0x0F: "Space-saving", 0x10: "Lunch Box", 0x11: "Main Server",
    0x1E: "低背板", 0x1F: "刀片", 0x23: "机架", 0x24: "密封机箱",
}

# 常见网卡芯片：软路由用户最关心的就是「是不是 2.5G」
_PCI_CHIPS = {
    "8086:125c": "Intel i226-V 2.5G",
    "8086:125b": "Intel i226-LM 2.5G",
    "8086:125d": "Intel i226-IT 2.5G",
    "8086:15f3": "Intel i225-V 2.5G",
    "8086:15f2": "Intel i225-LM 2.5G",
    "8086:15f1": "Intel i225-IT 2.5G",
    "10ec:8125": "Realtek RTL8125 2.5G",
    "10ec:8168": "Realtek RTL8111/8168 千兆",
    "10ec:8169": "Realtek RTL8169 千兆",
    "8086:1533": "Intel i210 千兆",
    "8086:157b": "Intel i210 千兆",
    "8086:15b8": "Intel i219-V 千兆",
    "8086:10d3": "Intel 82574L 千兆",
    "8086:1015": "Intel 82540EM 千兆",
    "8086:1521": "Intel i350 千兆",
    "14e4:165f": "Broadcom NetXtreme 千兆",
}

# DMI 里的占位符：不同主板厂商写法不一样，全都要当空值
_DMI_NOISE = re.compile(
    r"^(default string|system product name|system version|to be filled by o\.?e\.?m\.?|"
    r"not specified|not applicable|not available|unknown|oem|o\.e\.m\.|default|empty|none|n/a|"
    r"（空）|\s*)$",
    re.I,
)

_hw_cache: dict = {}
_hw_ts = 0.0
HW_TTL = 30.0


# ---------------------------------------------------------------- 基础设施

def _read(path: str, default: str = "") -> str:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read().strip()
    except OSError:
        return default


def _clean(value: str) -> str:
    """把 DMI 占位符当成空串，避免界面上出现一排 Default string"""
    t = (value or "").strip()
    return "" if _DMI_NOISE.match(t) else t


def _kb(v: int) -> str:
    for unit, div in (("TB", 1024 ** 3), ("GB", 1024 ** 2), ("MB", 1024)):
        if v >= div:
            return f"{v / div:.0f} {unit}" if v % div == 0 else f"{v / div:.1f} {unit}"
    return f"{v} KB"


# ---------------------------------------------------------------- SMBIOS

def _dmi_raw(kind: int, inst: int = 0) -> bytes:
    path = f"/sys/firmware/dmi/entries/{kind}-{inst}/raw"
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError:
        return b""


def _dmi_strings(raw: bytes, length: int) -> list[str]:
    """结构后面紧跟的就是字符串表：以 \\0 分隔、双 \\0 结束，索引从 1 开始。"""
    if not raw or length >= len(raw):
        return []
    tail = raw[length:]
    out: list[str] = []
    for chunk in tail.split(b"\x00"):
        if not chunk:
            break
        out.append(chunk.decode("utf-8", "replace").strip())
    return out


def _dmi_str(strings: list[str], idx: int) -> str:
    if 1 <= idx <= len(strings):
        return _clean(strings[idx - 1])
    return ""


def _u16(raw: bytes, off: int) -> int:
    if len(raw) < off + 2:
        return 0
    return raw[off] | (raw[off + 1] << 8)


def memory_modules() -> list[dict]:
    """SMBIOS Type 17：每根内存条的槽位、容量、类型、频率、厂商。"""
    out: list[dict] = []
    for inst in range(8):
        raw = _dmi_raw(17, inst)
        if not raw or raw[0] != 0x11:
            break
        length = raw[1] if len(raw) > 1 else 0
        strs = _dmi_strings(raw, length)

        size_mb = _u16(raw, 0x0C)
        if size_mb == 0x7FFF and len(raw) >= 0x20:
            size_mb = int.from_bytes(raw[0x1C:0x20], "little") & 0x7FFFFFFF
        elif size_mb & 0x8000:
            size_mb //= 1024
        if size_mb in (0, 0xFFFF):
            continue  # 空槽

        mtype = _MEM_TYPES.get(raw[0x12] if len(raw) > 0x12 else 0, "")
        speed = _u16(raw, 0x15)
        if speed == 0xFFFF and len(raw) >= 0x56:
            speed = _u16(raw, 0x54)  # SMBIOS 3.3 起的扩展频率
        form = _FORM_FACTORS.get(raw[0x0E] if len(raw) > 0x0E else 0, "")

        out.append({
            "slot": _dmi_str(strs, raw[0x10] if len(raw) > 0x10 else 0) or f"槽 {inst + 1}",
            "size_mb": size_mb,
            "size": _kb(size_mb * 1024),
            "type": mtype,
            "speed": speed if 0 < speed < 20000 else 0,
            "form": form,
            "vendor": _dmi_str(strs, raw[0x17] if len(raw) > 0x17 else 0),
            "part": _dmi_str(strs, raw[0x1A] if len(raw) > 0x1A else 0),
        })
    return out


def machine() -> dict:
    vendor = _clean(_read("/sys/class/dmi/id/sys_vendor"))
    product = _clean(_read("/sys/class/dmi/id/product_name"))
    board_vendor = _clean(_read("/sys/class/dmi/id/board_vendor"))
    board = _clean(_read("/sys/class/dmi/id/board_name"))
    chassis_raw = _read("/sys/class/dmi/id/chassis_type", "")

    chassis = ""
    try:
        chassis = _CHASSIS.get(int(chassis_raw), f"类型 {chassis_raw}")
    except ValueError:
        pass

    # 软路由的 DMI 基本都是占位符。这时候「BIOS 版本 + 内存 + 网卡」才是身份证明，
    # 所以额外给一句说明，别让用户以为读错了。
    sparse = not (vendor or product or board)
    return {
        "vendor": vendor,
        "product": product,
        "board_vendor": board_vendor,
        "board": board,
        "bios_vendor": _clean(_read("/sys/class/dmi/id/bios_vendor")),
        "bios_version": _read("/sys/class/dmi/id/bios_version"),
        "bios_date": _read("/sys/class/dmi/id/bios_date"),
        "chassis": chassis,
        "sparse": sparse,
        "note": "主板厂商信息是 BIOS 占位符（软路由常见），型号可参照内存与网卡配置判断"
        if sparse else "",
        "vendor_guess": _guess_vendor(board, product),
    }


def _guess_vendor(board: str, product: str) -> str:
    """从 BIOS 版本号 / 板卡名里认整机厂商。认出就显示，认不出留空。"""
    hay = f"{board} {product}".upper()
    for key, name in (
        ("CWWK", "畅网"), ("CHANGWANG", "畅网"), ("TOPTON", "拓普龙"),
        ("QOTOM", "Qotom"), ("HUNSN", "HUNSN"), ("KINGNOVY", "Kingnovy"),
        ("GIGABYTE", "技嘉"), ("ASUS", "华硕"), ("ASROCK", "华擎"),
        ("MSI", "微星"), ("DELL", "戴尔"), ("HP", "惠普"), ("LENOVO", "联想"),
    ):
        if key in hay:
            return name
    return ""


# ---------------------------------------------------------------- CPU

def cpu() -> dict:
    info = sysinfo.cpu_model()
    threads = 0
    flags = ""
    for line in _read("/proc/cpuinfo").splitlines():
        if line.startswith("processor"):
            threads += 1
        elif line.startswith("flags") and not flags:
            flags = line.split(":", 1)[1]
    cores = 0
    for line in _read("/proc/cpuinfo").splitlines():
        if line.lower().startswith("cpu cores"):
            try:
                cores = int(line.split(":", 1)[1])
            except ValueError:
                cores = 0
            break
    if not cores:
        cores = info["cores"] or threads

    mhz_now = 0.0
    for line in _read("/proc/cpuinfo").splitlines():
        if line.lower().startswith("cpu mhz"):
            try:
                mhz_now = float(line.split(":", 1)[1])
            except ValueError:
                pass
            break

    base = _read("/sys/devices/system/cpu/cpu0/cpufreq/base_frequency")
    maxf = _read("/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq")
    minf = _read("/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq")

    cache = ""
    for idx in (3, 2):
        raw = _read(f"/sys/devices/system/cpu/cpu0/cache/index{idx}/size")
        if raw:
            cache = (cache + " / " if cache else "") + raw.upper()
            break

    return {
        "model": info["model"],
        "cores": cores,
        "threads": threads,
        "mhz": round(mhz_now),
        "base_mhz": round(int(base) / 1000) if base.isdigit() else 0,
        "max_mhz": round(int(maxf) / 1000) if maxf.isdigit() else 0,
        "min_mhz": round(int(minf) / 1000) if minf.isdigit() else 0,
        "cache": cache,
        "arch": platform.machine(),
        "vt": "vmx" in flags or "svm" in flags,
        "aes": " aes " in f" {flags} ",
    }


# ---------------------------------------------------------------- 存储

def disks() -> list[dict]:
    out = []
    base = "/sys/block"
    try:
        names = sorted(os.listdir(base))
    except OSError:
        return out
    for name in names:
        if name.startswith(("loop", "ram", "zram", "nbd", "dm-", "md")):
            continue
        root = f"{base}/{name}"
        sectors = _read(f"{root}/size", "0")
        try:
            size = int(sectors) * 512
        except ValueError:
            size = 0
        if size <= 0:
            continue

        model = _read(f"{root}/device/model") or _read(f"{root}/device/name") or name
        transport = "NVMe" if name.startswith("nvme") else (
            "USB" if "/usb" in os.path.realpath(f"{root}/device") else "SATA")
        if name.startswith(("mmcblk", "sd")) and transport == "SATA" and not os.path.exists(
                f"{root}/device/model"):
            transport = "SD/USB"

        temp = 0.0
        if name.startswith("nvme"):
            # 盘的 hwmon 不在 /sys/class/nvme/<盘>/device/hwmon 下，
            # 统一从 /sys/class/hwmon 里找 name=nvme 的那个，和 sensors() 同一来源
            for hw in _glob("/sys/class/hwmon/hwmon*"):
                if _read(f"{hw}/name") != "nvme":
                    continue
                raw = _read(f"{hw}/temp1_input")
                if raw.lstrip("-").isdigit():
                    temp = round(int(raw) / 1000, 1)
                break
        out.append({
            "name": name,
            "model": model.strip(),
            "size": size,
            "size_text": _kb(size // 1024),
            "transport": transport,
            "temp": temp,
        })
    return out


def _glob(pattern: str) -> list[str]:
    import glob
    return sorted(glob.glob(pattern))


# ---------------------------------------------------------------- 网卡

def _pci_name_map() -> dict[str, str]:
    """lspci 的品牌名（有 pci.ids 时才有），按 slot 索引。"""
    out: dict[str, str] = {}
    text = sysinfo._run(["lspci", "-nn"], timeout=4)
    for line in text.splitlines():
        parts = line.split(None, 1)
        if len(parts) < 2:
            continue
        slot = parts[0]
        rest = parts[1]
        # 00:02.0 VGA compatible controller [0300]: Intel Corporation X [8086:46b3] (rev 0c)
        name = rest.split(":", 1)[1].strip() if ":" in rest else rest
        code = ""
        m = re.search(r"\[([0-9a-f]{4}:[0-9a-f]{4})\]", name)
        if m:
            code = m.group(1).lower()
            name = name[:m.start()].strip()
        name = re.sub(r"\(rev [0-9a-f]+\)$", "", name).strip()
        out[slot] = _PCI_CHIPS.get(code) or name
    return out


def nics() -> list[dict]:
    names = _pci_name_map()
    out = []
    for name in sorted(os.listdir("/sys/class/net") if os.path.isdir("/sys/class/net") else []):
        if name.startswith(("lo", "docker", "veth", "br-", "dummy", "erspan", "gre",
                            "gretap", "ip6", "sit", "teql", "tunl", "bonding", "utun")):
            continue
        if ":" in name or name in ("siit0",):
            continue
        uevent = _read(f"/sys/class/net/{name}/device/uevent")
        if "PCI_SLOT_NAME" not in uevent:
            continue  # 虚拟接口不列

        attrs = dict(
            line.split("=", 1) for line in uevent.splitlines() if "=" in line
        )
        slot = attrs.get("PCI_SLOT_NAME", "")
        code = (attrs.get("PCI_ID", "") or "").lower()
        chip = _PCI_CHIPS.get(code) or names.get(slot) or ""
        driver = attrs.get("DRIVER", "")

        speed = 0
        raw = _read(f"/sys/class/net/{name}/speed")
        if raw.lstrip("-").isdigit():
            speed = max(0, int(raw))

        addrs = []
        ipv4 = sysinfo._run(["ip", "-4", "-o", "addr", "show", "dev", name], timeout=3)
        for line in ipv4.splitlines():
            m = re.search(r"inet (\d+\.\d+\.\d+\.\d+/\d+)", line)
            if m:
                addrs.append(m.group(1))
        ipv6 = sysinfo._run(["ip", "-6", "-o", "addr", "show", "dev", name], timeout=3)
        for line in ipv6.splitlines():
            m = re.search(r"inet6 ([0-9a-f:]+/\d+)", line)
            if m and not m.group(1).startswith("fe80"):
                addrs.append(m.group(1))

        out.append({
            "name": name,
            "chip": chip,
            "driver": driver,
            "slot": slot,
            "speed_mbps": speed,
            "mac": _read(f"/sys/class/net/{name}/address"),
            "addrs": addrs,
            "up": _read(f"/sys/class/net/{name}/operstate") == "up",
        })
    return out


def pci_devices() -> list[dict]:
    out = []
    text = sysinfo._run(["lspci", "-nn"], timeout=4)
    for line in text.splitlines():
        parts = line.split(None, 1)
        if len(parts) < 2:
            continue
        rest = parts[1]
        cls = ""
        m = re.match(r"^(.*?) \[([0-9a-f]{4})\]:", rest)
        if m:
            cls = m.group(1)
            rest = rest[m.end():].strip()
        rest = re.sub(r"\s*\[[0-9a-f]{4}:[0-9a-f]{4}\]", "", rest)
        rest = re.sub(r"\s*\(rev [0-9a-f]+\)$", "", rest).strip()
        out.append({"slot": parts[0], "class": cls, "name": rest})
    return out


# ---------------------------------------------------------------- 传感器

def sensors() -> dict:
    zones = sysinfo.temperature()
    cores = []
    nvme = 0.0
    cpu_pkg = 0.0
    for hw in _glob("/sys/class/hwmon/hwmon*"):
        label = _read(f"{hw}/name")
        if label == "coretemp":
            for i in range(64):
                val = _read(f"{hw}/temp{i + 1}_input")
                name = _read(f"{hw}/temp{i + 1}_label")
                if not val.lstrip("-").isdigit():
                    continue
                c = round(int(val) / 1000, 1)
                if name.lower().startswith("package"):
                    cpu_pkg = c
                elif name:
                    cores.append({"label": name.replace("Core ", "核心 "), "celsius": c})
        elif label == "nvme":
            val = _read(f"{hw}/temp1_input")
            if val.lstrip("-").isdigit():
                nvme = round(int(val) / 1000, 1)

    top = max([c["celsius"] for c in cores], default=0.0)
    return {
        "cpu": cpu_pkg or top or (max((z["celsius"] for z in zones), default=0.0)),
        "nvme": nvme,
        "cores": cores,
        "zones": zones,
    }


# ---------------------------------------------------------------- 汇总

def system() -> dict:
    b = sysinfo.board()
    agent_version = ""
    try:
        from .server import VERSION  # 延迟导入，避免循环依赖
        agent_version = VERSION
    except Exception:
        agent_version = ""
    return {
        "hostname": b.get("hostname", ""),
        "distro": b.get("distribution", ""),
        "version": b.get("version", ""),
        "revision": b.get("revision", ""),
        "description": b.get("description", ""),
        "target": b.get("target", ""),
        "kernel": b.get("kernel", ""),
        "arch": platform.machine(),
        "agent": agent_version,
        "python": platform.python_version(),
        "boot": _boot_time(),
        "uptime": sysinfo.uptime(),
    }


def _boot_time() -> int:
    try:
        return int(time.time() - sysinfo.uptime())
    except Exception:
        return 0


def hardware(force: bool = False) -> dict:
    global _hw_cache, _hw_ts
    now = time.time()
    if not force and _hw_cache and now - _hw_ts < HW_TTL:
        return _hw_cache

    mem = sysinfo.memory()
    data = {
        "ok": True,
        "ts": int(now),
        "machine": machine(),
        "cpu": cpu(),
        "memory": {
            "total": mem.get("total", 0),
            "used": mem.get("used", 0),
            "percent": mem.get("percent", 0),
            "modules": memory_modules(),
        },
        "disks": disks(),
        "nics": nics(),
        "pci": pci_devices(),
        "sensors": sensors(),
        "system": system(),
    }
    _hw_cache = data
    _hw_ts = now
    return data
