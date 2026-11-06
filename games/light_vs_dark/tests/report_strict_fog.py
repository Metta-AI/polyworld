#!/usr/bin/env python3
"""Validate and summarize bench_strict_fog JSONL; stdlib only."""
import hashlib
import itertools
import json
import math
import statistics
import sys
from pathlib import Path
from typing import Any


def summarize(path):
    raw = path.read_bytes()
    rows = [json.loads(line) for line in raw.splitlines()]
    meta = rows[0]
    assert meta['type'] == 'metadata'
    assert rows[-1]['type'] == 'verified' and rows[-1]['gl_error'] == 0
    frames = [r for r in rows if r['type'] == 'frame']
    repeats, samples = meta['repeats'], meta['samples']
    assert repeats == 3
    expected = set(itertools.product(['sparse', 'dense'], [800, 1600],
                                    [False, True], range(repeats), range(samples)))
    keys = [(r['density'], r['width'], r['strict'], r['repeat'], r['sample']) for r in frames]
    assert len(keys) == len(set(keys)) and set(keys) == expected
    metrics = ['cpu_submit_ms', 'finish_wait_ms', 'complete_ms']
    if meta['gpu_timer']:
        metrics.append('gpu_ms')
    for r in frames:
        assert all(math.isfinite(r[m]) and r[m] >= 0 for m in metrics)
        assert r['height'] == r['width'] * 5 // 8
    result = dict(metadata=meta, verified=rows[-1], frame_count=len(frames),
                  sha256=hashlib.sha256(raw).hexdigest(), cases=[])
    for density, width in itertools.product(['sparse', 'dense'], [800, 1600]):
        group = [r for r in frames if r['density'] == density and r['width'] == width]
        assert len({(r['scenery_submitted'], r['buildings_submitted']) for r in group}) == 1
        case: dict[str, Any] = dict(density=density, width=width, height=width * 5 // 8,
                    scenery_submitted=group[0]['scenery_submitted'],
                    buildings_submitted=group[0]['buildings_submitted'], metrics={})
        for metric in metrics:
            values = {}
            for on in [False, True]:
                medians = [statistics.median(r[metric] for r in group
                           if r['strict'] == on and r['repeat'] == repeat)
                           for repeat in range(repeats)]
                ordered = sorted(r[metric] for r in group if r['strict'] == on)
                values['on' if on else 'off'] = dict(repeat_medians=medians,
                    median=statistics.median(medians), p95=ordered[math.ceil(len(ordered)*.95)-1])
            lookup = {(r['repeat'], r['sample'], r['strict']): r[metric] for r in group}
            delta = [statistics.median(lookup[(repeat, sample, True)] - lookup[(repeat, sample, False)]
                     for sample in range(samples)) for repeat in range(repeats)]
            values['paired_repeat_deltas'] = delta
            values['paired_delta_median'] = statistics.median(delta)
            values['paired_delta_range'] = [min(delta), max(delta)]
            case['metrics'][metric] = values
        for stage, index in [('ground_capture', 1), ('composite', 3)]:
            case[stage+'_cpu_ms'] = statistics.median(r['cpu_stages_ms'][index]
                                                      for r in group if r['strict'])
        result['cases'].append(case)
    return result


def main():
    path = Path(sys.argv[1])
    report = summarize(path)
    path.with_name('summary.json').write_text(json.dumps(report, indent=2)+'\n')
    print('Verified', report['frame_count'], 'unique frames;', report['metadata']['renderer'])
    print('Values: median of 3 repeat medians; delta median of 3 medians of adjacent on-minus-off pairs.')
    for case in report['cases']:
        print(case['density'], f"{case['width']}x{case['height']}")
        for metric, values in case['metrics'].items():
            print(f"  {metric}: {values['off']['median']:.3f} -> {values['on']['median']:.3f}; "
                  f"delta {values['paired_delta_median']:+.3f}; "
                  f"range [{values['paired_delta_range'][0]:+.3f}, {values['paired_delta_range'][1]:+.3f}]")
        print('  ground/composite CPU', round(case['ground_capture_cpu_ms'],3),
              round(case['composite_cpu_ms'],3))


if __name__ == '__main__':
    main()
