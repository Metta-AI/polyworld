"""Summarize verified benchmark JSON; keep raw timing out of the sim."""
import collections
import csv
import hashlib
import json
import pathlib
import statistics
import sys

root = pathlib.Path(sys.argv[1])
before = json.loads((root / 'before.json').read_text())
after = json.loads((root / 'after.json').read_text())
assert len(before) == len(after) == 80
rows = []
for scenario in ['opposing', 'crossing', 'choke', 'miners']:
    for count in [2, 20, 100, 300]:
        row = {'scenario': scenario, 'count': count}
        for label, data in [('before', before), ('after', after)]:
            group = [x for x in data if x['scenario'] == scenario and x['count'] == count]
            assert len(group) == 5
            assert len({x['hash'] for x in group}) == 1
            for metric in ['median_ns', 'p95_ns', 'completed', 'displacement_q16',
                           'stall_unit_ticks', 'overlap_pair_samples', 'peak_overlap_pairs',
                           'gold_gathered', 'path_searches', 'path_expansions']:
                row[label + '_' + metric] = statistics.median(x[metric] for x in group)
            row[label + '_mean_ns'] = statistics.median(statistics.mean(x['raw_tick_ns']) for x in group)
        rows.append(row)
with (root / 'summary.csv').open('w') as stream:
    writer = csv.DictWriter(stream, fieldnames=rows[0].keys())
    writer.writeheader()
    writer.writerows(rows)
(root / 'summary.json').write_text(json.dumps(rows, indent=2))
lines = ['|Workload|Units|Median µs before→after|p95 µs before→after|Completed before→after|Gold before→after|',
         '|---|---:|---:|---:|---:|---:|']
for r in rows:
    pair = lambda key, divisor=1: f"{r['before_'+key]/divisor:g}→{r['after_'+key]/divisor:g}"
    lines.append(f"|{r['scenario']}|{r['count']}|{pair('median_ns',1000)}|{pair('p95_ns',1000)}|{pair('completed')}|{pair('gold_gathered')}|")
(root / 'table.md').write_text('\n'.join(lines)+'\n')
profiles = {}
for label in ['before', 'after']:
    for scenario in ['opposing', 'miners']:
        events = json.loads((root / f'profile-{label}-{scenario}.json').read_text())['traceEvents']
        totals = collections.Counter()
        for event in events:
            if event['ph'] == 'X': totals[event['name']] += event['dur']
        profiles[label+'_'+scenario] = dict(totals)
(root / 'profile-summary.json').write_text(json.dumps(profiles, indent=2))
(root / 'candidate-binary.sha256').write_text(hashlib.sha256((root/'candidate').read_bytes()).hexdigest())
print('\n'.join(lines))
print(json.dumps(profiles, indent=2))
