#!/usr/bin/env python3
"""Select a full server snapshot, never a Codex-only or incomplete snapshot."""
import json
import re
import sys


def select(snapshots, requested='latest'):
    candidates = []
    for s in snapshots:
        tags = set(s.get('tags') or [])
        paths = set(s.get('paths') or [])
        identifier = s.get('id', '')
        if not re.fullmatch(r'[a-f0-9]{64}', identifier):
            continue
        if 'netcup' not in tags or tags & {'codex-sessions', 'backup-incomplete'}:
            continue
        if not {'/etc', '/usr/local/bin', '/opt/horus-backup/staging'} <= paths:
            continue
        if requested != 'latest' and not identifier.startswith(requested):
            continue
        candidates.append(s)
    if not candidates or (requested != 'latest' and len(candidates) != 1):
        raise ValueError('Nenhum snapshot completo e inequívoco disponível')
    return max(candidates, key=lambda s: s['time'])


if __name__ == '__main__':
    try:
        arg = sys.argv[1] if len(sys.argv) > 1 else 'latest'
        chosen = select(json.load(sys.stdin), 'latest' if arg == '--time' else arg)
        print(chosen['time'] if arg == '--time' else chosen['id'])
    except (ValueError, KeyError, TypeError) as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
