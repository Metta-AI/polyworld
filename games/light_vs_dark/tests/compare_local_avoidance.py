"""Three revisions, identical raw five-run workload; phases are separate probes."""
import collections
import json
import pathlib
import statistics as st
import sys
root = pathlib.Path(sys.argv[1])
files = {'baseline': 'baseline-final-comparison.json', 'candidate1': 'initial-final-comparison.json', 'final': 'final.json'}
data = {k: json.loads((root/v).read_text()) for k,v in files.items()}
for rows in data.values():
    assert len(rows) == 80
    assert all(len(r['raw_tick_ns']) == r['ticks'] == 900 for r in rows)
summary = []
lines = ['|Workload|Units|Median µs baseline / candidate1 / final|p95 µs baseline / candidate1 / final|Completed B / C / F|Gold B / C / F|', '|---|---:|---:|---:|---:|---:|']
for scenario in ['opposing','crossing','choke','miners']:
    for count in [2,20,100,300]:
        row = {'scenario':scenario,'count':count}
        for label,rows in data.items():
            group = [r for r in rows if r['scenario']==scenario and r['count']==count]
            assert len(group)==5 and len({r['hash'] for r in group})==1
            row[label] = {k: st.median(r[k] for r in group) for k in group[0] if isinstance(group[0][k], (int,float)) and k!='run'}
            row[label]['mean_ns'] = st.median(st.mean(r['raw_tick_ns']) for r in group)
        summary.append(row)
        def values(key,div=1):
            return ' / '.join(f'{row[k][key]/div:.2f}' if div!=1 else str(row[k][key]) for k in files)
        lines.append(f"|{scenario}|{count}|{values('median_ns',1000)}|{values('p95_ns',1000)}|{values('completed')}|{values('gold_gathered')}|")
(root/'three-way-summary.json').write_text(json.dumps(summary,indent=2))
(root/'three-way-table.md').write_text('\n'.join(lines)+'\n')
profiles = []
for label in ['baseline','initial','final']:
    for scenario,count in [('crossing',100),('crossing',300),('choke',300),('miners',300)]:
        prefix = root/f'diag-{label}-{scenario}{count}'
        events = []
        for chunk in range(18):
            part = json.loads(pathlib.Path(str(prefix)+f'-trace-{chunk}.json').read_text())['traceEvents']
            assert len(part) < 10000, 'Profiler trace cap invalidates phase totals'
            events.extend(part)
        work = json.loads(pathlib.Path(str(prefix)+'-work.json').read_text())
        totals = collections.Counter()
        counts = collections.Counter()
        for e in events:
            if e.get('ph')=='X':
                totals[e['name']] += e['dur']
                counts[e['name']] += 1
        assert counts['tickWorld*']==len(work)==900
        active = sum(r['active'] for r in work)
        moved = sum(r['moved'] for r in work)
        profiles.append({'revision':label,'scenario':scenario,'count':count,'phase_ms':{k:round(totals[k]/1000,3) for k in ['vision','searchPath','units','separate','tickWorld*']},'active_unit_ticks':active,'moving_unit_ticks':moved,'us_per_active_unit_tick':totals['tickWorld*']/active,'us_per_moving_unit_tick':totals['tickWorld*']/moved if moved else None,'searches':sum(r['searches'] for r in work),'expansions':sum(r['expansions'] for r in work)})
(root/'three-way-profiles.json').write_text(json.dumps(profiles,indent=2))
print('\n'.join(lines))
for r in profiles: print(r)
