#!/usr/bin/env python3
"""Compare shared code with the sibling checkout; neither build depends on the sibling."""
from pathlib import Path
import sys
root = Path(__file__).resolve().parents[1]
other = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else root.parent / ('silent_disco' if root.name == 'silent_disco_server' else 'silent_disco_server')
if not other.is_dir():
    raise SystemExit('Pass the other app checkout as an argument to compare shared sources.')
failures = []
files = [p.relative_to(root) for p in (root/'NativeAudio').rglob('*') if p.is_file() and not any(x in p.parts for x in ('.build', '.swiftpm'))]
files += [Path('lib/audio.dart'), Path('lib/diagnostics.dart'), Path('scripts/check_mirrors.py'), Path('scripts/verify_opus.py'), Path('docs/AUDIO_PROTOCOL.md'), Path('docs/AUDIO_TESTING.md')]
for rel in files:
    if not (other/rel).is_file() or (root/rel).read_bytes() != (other/rel).read_bytes(): failures.append(str(rel))
a = 'macos' if (root/'macos').is_dir() else 'ios'
b = 'macos' if (other/'macos').is_dir() else 'ios'
for rel in ['Audio/AudioBridge.swift', 'Diagnostics/DiagnosticBridge.swift', 'Diagnostics/DiagnosticEngine.swift', 'Diagnostics/DiagnosticProtocol.swift']:
    if (root/a/'Runner'/rel).read_bytes() != (other/b/'Runner'/rel).read_bytes(): failures.append(rel)
if failures:
    raise SystemExit('Different shared files:\n'+'\n'.join(failures))
print(f'Shared sources match ({len(files)+4} files).')
