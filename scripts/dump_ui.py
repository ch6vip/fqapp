#!/usr/bin/env python
"""Read the current device screen's UI labels via uiautomator.

Usage (from repo root):
    python scripts/dump_ui.py            # top ~40 labels with bounds
    python scripts/dump_ui.py --all      # every labeled node
    python scripts/dump_ui.py --package com.fqapp.fqapp

Flutter apps expose accessibility labels through ``content-desc`` while native
views use ``text``; reading only ``text`` makes every Flutter screen look
empty. Both are read here, ``text`` first, so the same script works for the
official client (native) and fqapp (Flutter).

Requires ``adb`` on PATH; ``uiautomator dump`` writes to /sdcard, which needs
no root on userdebug/eng devices and works through `su` where restricted.
"""

import argparse
import re
import subprocess
import sys
import tempfile
import os

_NODE = re.compile(r'<node[^>]*/?>')


def _attr(node: str, key: str) -> str:
    m = re.search(key + r'="([^"]*)"', node)
    return m.group(1) if m else ''


def dump() -> str:
    tmp = os.path.join(tempfile.gettempdir(), 'fqapp_ui_dump.xml')
    subprocess.run(
        ['adb', 'shell', 'uiautomator', 'dump', '/sdcard/fqapp_ui_dump.xml'],
        capture_output=True,
        timeout=30,
        env={**os.environ, 'MSYS_NO_PATHCONV': '1'},
    )
    with open(tmp, 'wb') as f:
        subprocess.run(
            ['adb', 'exec-out', 'cat', '/sdcard/fqapp_ui_dump.xml'],
            stdout=f,
            capture_output=False,
            timeout=30,
        )
    with open(tmp, encoding='utf-8', errors='replace') as f:
        return f.read()


def labels(xml: str, package: str | None):
    for node in _NODE.findall(xml):
        text = _attr(node, 'text') or _attr(node, 'content-desc')
        if not text.strip():
            continue
        pkg = _attr(node, 'package')
        if package and pkg != package:
            continue
        yield _attr(node, 'bounds'), text.replace('&#10;', ' | ')


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--all', action='store_true', help='print every label')
    ap.add_argument('--package', default=None)
    args = ap.parse_args()

    rows = list(labels(dump(), args.package))
    limit = None if args.all else 40
    for bounds, text in rows[:limit] if limit else rows:
        print('%-26s %s' % (bounds, text[:48]))
    print('-- %d labels' % len(rows))
    return 0


if __name__ == '__main__':
    sys.exit(main())
