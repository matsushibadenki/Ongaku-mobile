import json, sys
from pathlib import Path
import numpy as np
from scipy.signal import resample_poly
root=Path(sys.argv[1]);rows=[]
for platform in ('mobile','desktop'):
 for p in sorted((root/platform).glob('*.f32')):
  x=np.fromfile(p,dtype='<f4').reshape(-1,2);assert np.isfinite(x).all()
  sample=float(np.max(abs(x))); reconstructed=resample_poly(x,16,1,axis=0); peak=float(np.max(abs(reconstructed)))
  rate=int(p.stem.split('-')[1]); lo=int(.45*rate);hi=min(len(x),int(.58*rate));window=x[lo:hi]
  delta=float(np.max(np.abs(np.diff(window,axis=0))))
  span=reconstructed[int(.4*rate)*16:min(len(reconstructed),int(.8*rate)*16)]; fadePeak=float(np.max(abs(span)))
  rows.append({'platform':platform,'case':p.stem,'samplePeakDBFS':float(20*np.log10(max(sample,1e-20))),'reconstructed16xDBFS':float(20*np.log10(max(peak,1e-20))),'transitionMaxStep':delta,'transitionReconstructed16xDBFS':float(20*np.log10(max(fadePeak,1e-20)))})
assert len(rows)==18,len(rows)
(root/'peaks.json').write_text(json.dumps({'method':'16x scipy polyphase, not an ITU-certified true-peak measurement','rows':rows},indent=2)+'\n')
for platform in ('mobile','desktop'):
 for suffix in (['clip-on'] if platform=='mobile' else ['clip-on','clip-off']):
  items=[x for x in rows if x['platform']==platform and x['case'].endswith(suffix)]
  print(platform,suffix,'n',len(items),'worst',max(items,key=lambda x:x['reconstructed16xDBFS']))
print('above 0 dBFS:',sum(x['reconstructed16xDBFS']>0 for x in rows),'/',len(rows))

for platform in ('mobile','desktop'):
 for mode in (['clip-on'] if platform=='mobile' else ['clip-on','clip-off']):
  values=[x for x in rows if x['platform']==platform and x['case'].endswith(mode)]
  worst=max(values,key=lambda x:x['transitionReconstructed16xDBFS']);print(platform,mode,'during transition worst',worst['case'],worst['transitionReconstructed16xDBFS'])
