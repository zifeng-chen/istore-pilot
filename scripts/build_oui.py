#!/usr/bin/env python3
"""把 IEEE 官方 OUI 库转成 Agent 用的紧凑表。

输入  oui.csv（Registry,Assignment,Organization Name,Organization Address）
输出  agent/data/oui.txt.gz，每行 "AABBCC\\t厂商名"

厂商名做了精简：去掉 Co./Ltd./Inc. 这类后缀，过长的截断，
只为了在手机上能一行显示完。
"""

from __future__ import annotations

import csv
import gzip
import io
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "scripts", "oui.csv")
DST = os.path.join(ROOT, "agent", "data", "oui.txt.gz")

# 按长到短排，避免 "Co., Ltd." 被 "Ltd." 先吃掉
SUFFIX = [
    "Co., Ltd.", "Co.,Ltd.", "Co. Ltd.", "Co Ltd", "Company Limited", "Limited",
    "Corporation", "Corp", "Incorporated", "Inc", "Ltd", "LLC", "GmbH",
    "S.p.A.", "S.A.", "B.V.", "AG", "KG", "Oy", "SAS", "SARL", "Pty",
    "Technology", "Technologies", "Electronic", "Electronics", "Communication",
    "Communications", "Industrial", "Industries", "International", "Group",
    "Holdings", "Holding", "Systems", "System", "Solutions", "Networks",
    "Network", "Digital", "Electric", "Electrical", "Manufacturing",
    "Enterprise", "Enterprises", "Computer", "Computers", "Products",
    "Devices", "Device", "Semiconductor", "Microelectronics", "Information",
    "Software", "Service", "Services", "Trading", "Import", "Export",
]

# 开头的城市名单独处理，不然只删结尾没用
CITY = [
    "Shenzhen", "Guangzhou", "Dongguan", "Beijing", "Shanghai", "Hangzhou",
    "Nanjing", "Suzhou", "Huizhou", "Zhuhai", "Xiamen", "Chengdu", "Wuhan",
    "Foshan", "Ningbo", "Tianjin", "Xi'an", "Zhongshan", "Wuxi", "Qingdao",
    "HangZhou", "ShenZhen", "BeiJing", "ShangHai",
]

# 子串命中就归到这个牌子，比机械删后缀可读得多
BRAND = [
    ("xiaomi", "小米"), ("mi.com", "小米"), ("apple", "Apple"),
    ("huawei", "华为"), ("honor", "荣耀"), ("oppo", "OPPO"), ("vivo", "vivo"),
    ("oneplus", "一加"), ("meizu", "魅族"), ("samsung", "三星"),
    ("sony", "索尼"), ("lg electronics", "LG"), ("tcl", "TCL"),
    ("tp-link", "TP-Link"), ("tplink", "TP-Link"), ("ruijie", "锐捷"),
    ("h3c", "H3C"), ("zte", "中兴"), ("espressif", "乐鑫 Espressif"),
    ("tuya", "涂鸦智能"), ("broadlink", "博联"), ("midea", "美的"),
    ("gree", "格力"), ("haier", "海尔"), ("hisense", "海信"),
    ("roborock", "石头科技"), ("ecovacs", "科沃斯"), ("dreame", "追觅"),
    ("yeelink", "Yeelight"), ("yeelight", "Yeelight"), ("aqara", "Aqara"),
    ("lumi united", "Aqara"), ("itead", "Sonoff"), ("sonoff", "Sonoff"),
    ("realtek", "瑞昱 Realtek"), ("intel", "Intel"), ("qualcomm", "高通"),
    ("broadcom", "博通"), ("mediatek", "联发科"), ("marvell", "Marvell"),
    ("asus", "华硕"), ("asustek", "华硕"), ("netgear", "网件 Netgear"),
    ("ubiquiti", "Ubiquiti"), ("synology", "群晖"), ("qnap", "威联通"),
    ("raspberry", "树莓派"), ("hon hai", "富士康"), ("foxconn", "富士康"),
    ("chicony", "群光电子"), ("liteon", "光宝"), ("pegatron", "和硕"),
    ("quanta", "广达"), ("compal", "仁宝"), ("wistron", "纬创"),
    ("tenda", "腾达"), ("mercury", "水星"), ("hikvision", "海康威视"),
    ("dahua", "大华"), ("imou", "乐橙"), ("ezviz", "萤石"), ("uniview", "宇视"),
    ("amazon", "Amazon"), ("google", "Google"), ("microsoft", "微软"),
    ("sonos", "Sonos"), ("nintendo", "任天堂"), ("philips", "飞利浦"),
    ("signify", "昕诺飞 Signify"), ("ikea", "宜家"), ("roku", "Roku"),
    ("vmware", "VMware"), ("qemu", "QEMU 虚拟机"), ("parallels", "Parallels"),
    ("virtualbox", "VirtualBox"), ("xen", "Xen 虚拟机"),
    ("dell", "Dell"), ("hewlett", "HP"), ("hp inc", "HP"), ("lenovo", "联想"),
    ("acer", "宏碁"), ("toshiba", "东芝"), ("panasonic", "松下"),
    ("canon", "佳能"), ("epson", "爱普生"), ("brother", "兄弟"),
    ("kingston", "金士顿"), ("seagate", "希捷"), ("western digital", "西部数据"),
    ("toshiba", "东芝"), ("supermicro", "超微"), ("gigabyte", "技嘉"),
    ("micro-star", "微星"), ("asrock", "华擎"),
    ("edimax", "Edimax"), ("d-link", "D-Link"), ("dlink", "D-Link"),
    ("linksys", "Linksys"), ("buffalo", "Buffalo"), ("mikrotik", "MikroTik"),
    ("aruba", "Aruba"), ("ruckus", "Ruckus"), ("cisco", "Cisco"),
    ("juniper", "Juniper"), ("fortinet", "Fortinet"), ("sophos", "Sophos"),
    ("nokia", "诺基亚"), ("ericsson", "爱立信"), ("motorola", "摩托罗拉"),
    ("vtech", "伟易达"), ("garmin", "佳明"), ("fitbit", "Fitbit"),
    ("withings", "Withings"), ("ring", "Ring"), ("nest", "Nest"),
    ("roborock", "石头科技"), ("viomi", "云米"), ("huami", "华米"),
    ("anker", "Anker"), ("belkin", "Belkin"), ("logitech", "罗技"),
    ("razer", "雷蛇"), ("steelseries", "赛睿"), ("nvidia", "NVIDIA"),
    ("amd", "AMD"), ("advanced micro devices", "AMD"),
    ("siemens", "西门子"), ("bosch", "博世"), ("honeywell", "霍尼韦尔"),
    ("schneider", "施耐德"), ("abb", "ABB"), ("legrand", "罗格朗"),
]

BRACKETS = re.compile(r"[\(（\[【].*?[\)）\]】]")
NON_WORD = re.compile(r"[^0-9A-Za-z\u4e00-\u9fff \.\-&']+")


def brand_of(name: str) -> str:
    low = name.lower()
    for key, label in BRAND:
        if key in low:
            return label
    return ""


def tidy(name: str) -> str:
    out = BRACKETS.sub(" ", name)
    out = NON_WORD.sub(" ", out)
    out = re.sub(r"\s+", " ", out).strip(" .,-")

    for city in CITY:
        if out.startswith(city) and len(out) > len(city) + 2:
            out = out[len(city):].strip(" .,-")
            break

    changed = True
    while changed:
        changed = False
        for suf in SUFFIX:
            for sep in (" ", ",", " &"):
                tail = sep + suf
                if out.lower().endswith(tail.lower()) and len(out) > len(tail) + 2:
                    out = out[: -len(tail)].strip(" .,-&")
                    changed = True
        if out.upper().endswith(" CO") and len(out) > 6:
            out = out[:-3].strip(" .,-&")
            changed = True

    return out.strip() or name.strip()[:24]


def main() -> int:
    if not os.path.exists(SRC):
        print(f"缺少源文件 {SRC}")
        return 1

    rows: dict[str, str] = {}
    with open(SRC, "r", encoding="utf-8", errors="replace", newline="") as fh:
        for row in csv.DictReader(fh):
            oui = (row.get("Assignment") or "").strip().upper()
            org = (row.get("Organization Name") or "").strip()
            if len(oui) != 6 or not org:
                continue
            rows[oui] = (brand_of(org) or tidy(org))[:22]

    os.makedirs(os.path.dirname(DST), exist_ok=True)
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", compresslevel=9, mtime=0) as gz:
        for oui in sorted(rows):
            gz.write(f"{oui}\t{rows[oui]}\n".encode("utf-8"))
    blob = buf.getvalue()
    with open(DST, "wb") as fh:
        fh.write(blob)

    print(f"写入 {DST}")
    print(f"  厂商条目 {len(rows)}")
    print(f"  文件大小 {len(blob) / 1024:.0f} KB")
    for probe in ("000C29", "1CB3C9", "68ABBC", "34EA34", "5CE50C"):
        print(f"  样例 {probe} -> {rows.get(probe, '(无)')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
