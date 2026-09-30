#!/usr/bin/env python3
"""Print version-specific release notes for tag and core-update workflows."""
import argparse
from pathlib import Path
import re
import subprocess


def git(*args):
    return subprocess.check_output(['git', *args], text=True).strip()


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('tag')
parser.add_argument('--previous-core')
args = parser.parse_args()
if not re.fullmatch(r'v\d+\.\d+\.\d+', args.tag):
    parser.error('Expected a stable version tag, such as v1.1.0')

version = args.tag[1:]
changelog = Path('CHANGELOG.md')
notes = []
if changelog.exists():
    collecting = False
    for line in changelog.read_text().splitlines():
        if line.startswith('## '):
            if collecting:
                break
            collecting = line.startswith(f'## [{version}]')
            continue
        if collecting:
            notes.append(line)

core = Path('core/mihomo-version.txt').read_text().strip()
if not ''.join(notes).strip():
    notes = ['### 内核更新', '', f'- mihomo：{args.previous_core + " → " if args.previous_core else ""}{core}。']

print('\n'.join(notes).strip())
print(f'\n### 镜像\n\n- `ghcr.io/bctjo/docker-clash:{version}`\n- `ghcr.io/bctjo/docker-clash:latest`\n- 平台：`linux/amd64`、`linux/arm64`。\n- 内核：`{core}`。')
tags = [tag for tag in git('tag', '--merged', 'HEAD', '--sort=-version:refname').splitlines()
        if re.fullmatch(r'v\d+\.\d+\.\d+', tag) and tag != args.tag]
if tags:
    print(f'\n[完整改动](https://github.com/bctjo/docker-clash/compare/{tags[0]}...{args.tag})')
