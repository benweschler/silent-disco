#!/usr/bin/env python3
"""Verify vendored codec hashes; optionally verify them against the pinned upstream tarball."""
from pathlib import Path
import hashlib, json, sys, tarfile
root = Path(__file__).resolve().parents[1]/'NativeAudio'
expected = json.loads((root/'OPUS-SHA256.json').read_text())
for name, digest in expected.items():
    if hashlib.sha256((root/name).read_bytes()).hexdigest() != digest:
        raise SystemExit('Changed codec source: '+name)
if len(sys.argv) > 1:
    archive = Path(sys.argv[1])
    if hashlib.sha256(archive.read_bytes()).hexdigest() != '6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1':
        raise SystemExit('Wrong upstream archive checksum')
    with tarfile.open(archive) as tar:
        for name, digest in expected.items():
            upstream = 'COPYING' if name == 'OPUS-LICENSE.txt' else name.removeprefix('Sources/COpus/')
            data = tar.extractfile('opus-1.6.1/'+upstream).read()
            if hashlib.sha256(data).hexdigest() != digest:
                raise SystemExit('Upstream mismatch: '+name)
print(f'Opus 1.6.1 verified ({len(expected)} files).')
