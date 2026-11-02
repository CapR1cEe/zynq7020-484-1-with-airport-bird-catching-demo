#!/usr/bin/env python3
"""Verify the unpacked distribution and optionally its ZIP using only stdlib."""
import argparse
import ast
import csv
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import zipfile


def verify(root, archive=None):
    root = root.resolve()
    expected = {}
    for line in (root/'SHA256SUMS.txt').read_text(encoding='utf-8').splitlines():
        digest, name = line.split('  ', 1)
        path = PurePosixPath(name)
        if path.is_absolute() or '..' in path.parts or not re.fullmatch('[0-9a-f]{64}', digest):
            raise ValueError(f'Unsafe manifest entry: {name}')
        if name in expected:
            raise ValueError(f'Duplicate manifest entry: {name}')
        expected[name] = digest
    actual = {p.relative_to(root).as_posix(): p for p in root.rglob('*') if p.is_file()}
    if set(actual) != set(expected) | {'SHA256SUMS.txt'}:
        raise ValueError('Manifest and distribution file lists differ')
    for name, digest in expected.items():
        if actual[name].is_symlink() or hashlib.sha256(actual[name].read_bytes()).hexdigest() != digest:
            raise ValueError(f'Hash mismatch: {name}')
    for path in actual.values():
        if path.suffix == '.json':
            json.loads(path.read_text(encoding='utf-8'))
        elif path.suffix == '.py':
            ast.parse(path.read_text(encoding='utf-8'), filename=str(path))
        elif path.suffix == '.csv':
            rows = list(csv.reader(path.read_text(encoding='utf-8').splitlines()))
            if any(len(row) != len(rows[0]) for row in rows):
                raise ValueError(f'Ragged CSV: {path}')
        elif path.suffix == '.md':
            for target in re.findall(r'\[[^\]]*\]\(([^)]+)\)', path.read_text(encoding='utf-8')):
                if re.match(r'https?://|#', target):
                    continue
                target = target.split('#')[0]
                if not target:
                    continue
                resolved = (path.parent/target).resolve()
                if root not in resolved.parents or not resolved.exists():
                    raise ValueError(f'Broken/nonportable link in {path.name}: {target}')
    for name in ['plugin.json']:
        plugin = json.loads((root/name).read_text(encoding='utf-8'))
        if plugin['name'] != 'ross-rtl-pipeline-community' or plugin['version'] != '2.2.0':
            raise ValueError(f'Unexpected plugin identity: {name}')
    if archive:
        with zipfile.ZipFile(archive) as z:
            bad = z.testzip()
            if bad:
                raise ValueError(f'ZIP CRC failed: {bad}')
            entries = [i for i in z.infolist() if not i.is_dir()]
            prefix = root.name + '/'
            names = [i.filename for i in entries]
            if len(set(names)) != len(names) or set(names) != {prefix+n for n in actual}:
                raise ValueError('ZIP file list differs from distribution')
            for info in entries:
                relative = info.filename[len(prefix):]
                if z.read(info) != actual[relative].read_bytes():
                    raise ValueError(f'ZIP content differs: {info.filename}')
    return {'status': 'passed', 'files': len(actual), 'hashes_verified': len(expected),
            'archive_verified': bool(archive)}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--archive', type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.root, args.archive), indent=2))
