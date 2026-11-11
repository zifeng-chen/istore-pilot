#!/usr/bin/env python3
"""入口：python3 run.py

    python3 run.py                          # 正常模式
    python3 run.py --record --demo-dir DIR  # 在真机上录制演示数据
    python3 run.py --demo --demo-dir DIR    # 云端只读回放
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from agent.server import serve


def main() -> int:
    ap = argparse.ArgumentParser(description="iStore Pilot Agent")
    ap.add_argument("--record", action="store_true", help="录制 GET 响应到 --demo-dir")
    ap.add_argument("--demo", action="store_true", help="只读回放演示数据")
    ap.add_argument("--demo-dir", default="", help="演示数据目录（默认 agent/demo）")
    ap.add_argument("--host", default="", help="覆盖监听地址（云端用 0.0.0.0）")
    ap.add_argument("--port", type=int, default=0, help="覆盖监听端口")
    args = ap.parse_args()

    # 复用现有的环境变量入口，不另造一套配置
    if args.host:
        os.environ["ISTORE_AGENT_HOST"] = args.host
    if args.port:
        os.environ["ISTORE_AGENT_PORT"] = str(args.port)
    serve(record=args.record, demo=args.demo, demo_dir=args.demo_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
