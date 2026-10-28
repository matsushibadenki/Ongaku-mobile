"""Compare paired rendered stereo PCM after attenuation-only BS.1770 matching."""
import json, sys
from pathlib import Path
import numpy as np
from scipy.signal import resample_poly
root=Path(sys.argv[1]); levels=json.loads(Path(sys.argv[2]).read_text()); output=Path(sys.argv[3]); rows=[]
pairs=[('bare','vocal35'),('bare','vocal100'),('opto0','opto35'),('exciter0','exciter35'),('space0','space35'),('all0','all35')]
def rms(x): return float(np.sqrt(np.mean(x.astype(np.float64)**2)))
def db(v): return float(20*np.log10(v)) if v>1e-20 else None
def band(x,rate,low,high):
 n=len(x); f=np.fft.rfftfreq(n,1/rate); y=np.fft.rfft(x.astype(np.float64),axis=0); w=np.ones(len(f))*2; w[0]=1
 if n%2==0: w[-1]=1
 return np.sqrt(np.sum(abs(y[(f>=low)&(f<high)])**2*w[(f>=low)&(f<high),None])/(n*n*2))
for fixture in sorted({x.name.split('--',1)[1] for x in root.glob('*.f32')}):
 rate=int(fixture[:-4].split('-')[-1])
 for a,b in pairs:
  names=[a+'--'+fixture,b+'--'+fixture]
  data=[np.fromfile(root/n,dtype='<f4').reshape(-1,2) for n in names]
  assert data[0].shape == data[1].shape and all(np.isfinite(x).all() for x in data)
  lu=[levels.get(n) for n in names]; powers=[rms(x) for x in data]
  if all(x is not None for x in lu):
   target=min(-23,*lu); gain=[10**((target-x)/20) for x in lu]; method='BS.1770 integrated'
  elif min(powers)>0:
   target=min(powers); gain=[target/x for x in powers]; method='RMS (gated)'
  elif max(powers)==0: gain=[1,1]; method='silence'
  else: raise RuntimeError('one side silent: '+fixture+' '+a)
  matched=[x*g for x,g in zip(data,gain)]; shared=min(1,.8/max(float(np.max(abs(x))) for x in matched)) if max(powers)>0 else 1
  gain=[g*shared for g in gain]; matched=[x*shared for x in matched]
  assert max(gain)<=1.000001
  bands=[]
  for lo,hi in [(1500,5000),(5000,8000)]:
   p,q=[band(x,rate,lo,hi) for x in matched]; bands.append(db(q/p) if p>1e-20 else None)
  peaks=[float(np.max(abs(x))) for x in data]
  over=[float(np.max(abs(resample_poly(x,4,1,axis=0)))) for x in data]
  residual=rms(matched[1]-matched[0]); base=rms(matched[0])
  tails=[rms(x[-rate:]) for x in matched]
  def corr(x):
   l=x[:,0].astype(np.float64);r=x[:,1].astype(np.float64);d=np.sqrt(np.dot(l,l)*np.dot(r,r));return float(np.dot(l,r)/d) if d else None
  rows.append(dict(fixture=fixture,pair=a+' / '+b,method=method,rawLUFS=lu,gainDB=[db(x) for x in gain],matchedLUFS=[x+db(g) if x is not None else None for x,g in zip(lu,gain)],presenceBandDeltaDB=bands[0],highBandDeltaDB=bands[1],residualRelativeDB=db(residual/base) if base else None,tailRMSDB=[db(x) for x in tails],stereoCorrelation=[corr(x) for x in matched],rawSamplePeakDBFS=[db(x) for x in peaks],rawReconstructed4xPeakDBFS=[db(x) for x in over]))
output.write_text(json.dumps({'rows':rows,'peakMethod':'scipy resample_poly 4x diagnostic, not certified true peak','loudness':'production IntegratedLoudnessMeter; each pair attenuation-only to common LUFS <= -23, then shared sample peak <= -1.94 dBFS; gated signals matched by RMS'},indent=2,allow_nan=False)+'\n')
print('PASS',len(rows),'matched comparisons')
