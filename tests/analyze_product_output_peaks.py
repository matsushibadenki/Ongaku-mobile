"""Measure captured stereo output after the simulated output-rate conversion."""
import json, sys
from pathlib import Path
import numpy as np
from scipy.signal import resample_poly
root=Path(sys.argv[1]); result=[]; violations=[]
t=np.arange(4096); tone=1.12*np.sin(np.pi*t/2+np.pi/4); taper=np.minimum(1,np.minimum(t,4095-t)/128); reconstructed=np.max(np.abs(resample_poly(tone*taper,16,1)))
assert abs(reconstructed-1.12)<0.003 and np.max(np.abs(tone*taper))<0.8, reconstructed
for platform in ('mobile','desktop'):
 for file in sorted((root/platform).glob('*.f32')):
  pcm=np.fromfile(file,dtype='<f4').reshape(-1,2)
  assert np.isfinite(pcm).all()
  sample=float(np.max(np.abs(pcm)))
  peak=float(np.max(np.abs(resample_poly(pcm,16,1,axis=0))))
  def db(x): return float(20*np.log10(x)) if x else None
  entry={'platform':platform,'case':file.stem,'frames':len(pcm),'samplePeakDBFS':db(sample),'reconstructed16xDBFS':db(peak)}
  if ('-truepeak-' in file.name and peak>10**(-1/20)+.002) or ('-stock-' in file.name and peak>1.000001):
   violations.append(entry)
  result.append(entry)
assert len(result)==144, len(result)
(root/'peaks.json').write_text(json.dumps({'method':'16x scipy resample_poly; diagnostic estimate, not ITU-certified','rows':result},indent=2,allow_nan=False)+'\n')
print(('FAIL' if violations else 'PASS'),len(result),'captured graphs; final-protector 16x estimates within -1 dBFS + 0.002 amplitude')
for platform in ('mobile','desktop'):
 for path in ('stock','truepeak'):
  rows=[x for x in result if x['platform']==platform and '-'+path+'-' in x['case']]
  worst=max(rows,key=lambda x:x['reconstructed16xDBFS'])
  print(platform,path,'worst:',worst['case'],round(worst['reconstructed16xDBFS'],3),'dBFS; above 0:',sum(x['reconstructed16xDBFS']>0 for x in rows),'/',len(rows))
if violations: raise RuntimeError('captured output exceeded the condition-specific peak limit: '+str(violations))
# The observed unprotected signal supplies a real negative control for the ceiling assertion.
lookup={(x['platform'],x['case']):x for x in result}
negative=[x for x in result if '-stock-' in x['case'] and x['reconstructed16xDBFS'] > 20*np.log10(10**(-1/20)+.002) and (x['platform'],x['case'].replace('-stock-','-truepeak-')) in lookup]
assert reconstructed > 10**(-1/20)+.002, 'calibration must exercise ceiling failure'
print('PASS: calibrated over-ceiling sine is rejected')
if negative: print('Observed stock negative control:', negative[0]['platform'], negative[0]['case'])
