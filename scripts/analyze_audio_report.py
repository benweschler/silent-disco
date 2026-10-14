#!/usr/bin/env python3
"""Summarize schema-2 audio evidence without equating timestamps with acoustic skew."""
import argparse
import json
from collections import Counter
from pathlib import Path


def summarize(path):
    report = json.loads(path.read_text())
    print(f'{path.name}: policy={report.get("buildInfo", {}).get("diagnosticPolicyVersion", "unknown")} '
          f'final={report.get("completeCounters")} marked={report.get("userReportedAudibleInterruptions", 0)}')
    print('  finalization:', json.dumps(report.get('finalization', {}), sort_keys=True))
    for row in report.get('listeners', []):
        stats = row.get('stats', {})
        diagnostics = stats.get('diagnostics', {})
        events = diagnostics.get('events', [])
        kinds = Counter(event.get('kind') for event in events)
        renderer = stats.get('rendererDiagnostics', {})
        calls = renderer.get('timestampCalls', {}).get('aggregate', {})
        print(f'  {row.get("name", row.get("id"))}: final={row.get("finalCounters")} '
              f'evidence={row.get("diagnosticDeliveryComplete", "legacy")} '
              f'PLC={stats.get("concealedFrames", "unknown")} underruns={stats.get("underruns", "unknown")}')
        print('    timing episodes:', dict((k, kinds[k]) for k in ('timingDegraded', 'timingEpisodeEnded')))
        print('    recoveries:', renderer.get('recoveryCounts', {}), 'slow passes:', kinds['slowRendererPass'])
        print('    timestamp maxima ms:', calls.get('maxDurationsMs', {}))
        print('    evidence loss:', {k: diagnostics.get(k) for k in
              ('retentionOverflow', 'hostRetentionOverflow', 'declaredTransportEvictions', 'observedSequenceGaps', 'delivery')})
    print('  Acoustic synchronization:', report.get('acousticSynchronization', 'unverified'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('reports', nargs='+', type=Path)
    args = parser.parse_args()
    for path in args.reports:
        summarize(path)


if __name__ == '__main__':
    main()
