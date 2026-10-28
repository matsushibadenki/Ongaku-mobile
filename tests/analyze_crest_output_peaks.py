import json, sys
from pathlib import Path
import numpy as np
from scipy.signal import resample_poly
root=Path(sys.argv[1]);rows=[]
t=np.arange(4096);tone=1.12*np.sin(np.pi*t/2+np.pi/4);taper=np.minimum(1,np.minimum(t,4095-t)/128)
assert abs(np.max(abs(resample_poly(tone*taper,16,1)))-1.12)<.003
for platform in ('mobile','desktop'):
 for p in sorted((root/platform).glob('*.f32')):
  pcm=np.fromfile(p,dtype='<f4').reshape(-1,2)
  assert np.isfinite(pcm).all()
  sample=float(np.max(abs(pcm))); peak=float(np.max(abs(resample_poly(pcm,16,1,axis=0))))
  rows.append({'platform':platform,'case':p.stem,'samplePeakDBFS':float(20*np.log10(max(sample,1e-20))),'reconstructed16xDBFS':float(20*np.log10(max(peak,1e-20)))})
assert len(rows)==36,len(rows)
(root/'peaks.json').write_text(json.dumps({'method':'16x polyphase; diagnostic estimate, not ITU-certified','rows':rows},indent=2)+'\n')
for platform in ('mobile','desktop'):
 for mode in ('stable','handoff'):
  group=[x for x in rows if x['platform']==platform and x['case'].startswith(mode+'-')]
  print(platform,mode,'n=',len(group),'worst=',max(group,key=lambda x:x['reconstructed16xDBFS']))
print('CASES ABOVE 0 dBFS:',sum(x['reconstructed16xDBFS']>0 for x in rows),'/',len(rows))
nulls=[]
for platform in ('mobile','desktop'):
 for p in sorted((root/platform).glob('stable-*.f32')):
  q=p.with_name(p.name.replace('stable-','handoff-',1))
  a=np.fromfile(p,dtype='<f4'); b=np.fromfile(q,dtype='<f4'); assert a.shape==b.shape
  nulls.append({'platform':platform,'pair':p.stem,'maxAbsoluteDifference':float(np.max(abs(a-b)))})
(root/'handoff-null.json').write_text(json.dumps(nulls,indent=2)+'\n')
for platform in ('mobile','desktop'):
 group=[r for r in nulls if r['platform']==platform]
 print(platform,'handoff vs stable maximum PCM difference',max(x['maxAbsoluteDifference'] for x in group))

if any(x['reconstructed16xDBFS'] > 0 for x in rows): raise RuntimeError('captured normal output exceeded 0 dBFS reconstructed peak')
if any(x['maxAbsoluteDifference'] > .001 for x in nulls): raise RuntimeError('correlated handoff changed output excessively')
print('PASS: all captured normal outputs below 0 dBFS; correlated handoff null difference < 0.001')
