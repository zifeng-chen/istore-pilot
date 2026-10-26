#!/usr/bin/env python3
"""入口：python3 run.py"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from agent.server import serve

if __name__ == "__main__":
    serve()
