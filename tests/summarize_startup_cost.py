#!/usr/bin/env python3
"""Summarize three rotated process launches per build; no cross-platform timing claim."""
import json, math, statistics, sys
from pathlib import Path
root=Path(sys.argv[1]); platform=sys.argv[2]
configs=['ordinary','gain','gain-truepeak']; results={}; formats=set()
for config in configs:
    paths=sorted(root.glob(f'{platform}-{config}-[0-2].json'))
    if len(paths)!=3: raise SystemExit(f'Expected 3 {platform}/{config} reports, got {len(paths)}')
    for path in paths:
        report=json.loads(path.read_text()); assert report['configuration']==config
        assert len(report['samples'])==2
        for sample in report['samples']:
            rate=sample['source_rate']; formats.add((rate,sample['processing_rate'],sample['output_rate'],sample['output_channels']))
            counts={}
            for row in sample['rows']:
                stage=row['stage']; index=counts.get(stage,0); counts[stage]=index+1
                for metric in ['wall_ms','cpu_ms','process_peak_rss_bytes']:
                    value=row[metric]; assert math.isfinite(value) and value>=0
                    results.setdefault((config,rate,stage,index,metric),[]).append(value)
            for required in ['controller.init','cold-load.ready','same-instance-reload.ready','cold-load.resume','same-instance-reload.resume']:
                assert counts.get(required)==1, (path,required,counts)
print('source_rate,processing_rate,output_rate,output_channels')
for item in sorted(formats): print(','.join(map(str,item)))
print('\nconfiguration,source_rate,stage,occurrence,metric,n,median,min,max')
for key,values in sorted(results.items()):
    assert len(values)==3,(key,len(values))
    print(','.join(map(str,(*key,len(values),round(statistics.median(values),4),round(min(values),4),round(max(values),4)))))
