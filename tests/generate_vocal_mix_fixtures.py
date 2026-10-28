"""Generate original synthetic stereo fixtures; no recorded voice or music."""
import hashlib, json, sys
from pathlib import Path
import numpy as np
from scipy.signal import butter, sosfilt
out=Path(sys.argv[1]);out.mkdir(parents=True,exist_ok=True)
manifest=[]
for rate in (48000,96000):
 t=np.arange(rate*4,dtype=np.float64)/rate
 rng=np.random.default_rng(4831)
 noise=rng.standard_normal(len(t))
 phase=2*np.pi*np.cumsum(175+18*np.sin(2*np.pi*.28*t)+5*np.sin(2*np.pi*4.7*t))/rate
 env=np.maximum(0,np.sin(2*np.pi*1.15*t))**.8
 env*=np.minimum(1,t/.06)*np.minimum(1,(4-t)/.05)
 voice=np.zeros_like(t)
 f0=175+18*np.sin(2*np.pi*.28*t)+5*np.sin(2*np.pi*4.7*t)
 for h in range(1,29):
  hz=h*f0
  form=.15+np.exp(-((hz-650)/300)**2)+.8*np.exp(-((hz-1450)/500)**2)+.55*np.exp(-((hz-2700)/650)**2)
  voice+=np.sin(h*phase+.13*h)*form/h
 voice*=.18*env
 # Short synthetic fricative-like bursts, not actual speech.
 hiss=sosfilt(butter(3,[5000,8000],btype='bandpass',fs=rate,output='sos'),noise)
 bursts=sum(np.exp(-((t-x)/.045)**2) for x in [.45,1.32,2.12,3.03])
 voice+=.025*hiss*bursts
 drums=np.zeros_like(t);pluck=np.zeros_like(t)
 for onset in np.arange(.25,4,.5):
  u=t-onset;active=(u>=0)&(u<.35);v=np.maximum(u,0)
  drums+=active*(.17*np.exp(-v/.015)*noise+.21*np.exp(-v/.08)*np.sin(2*np.pi*75*v))
  pluck+=active*.13*np.exp(-v*9)*sum(np.sin(2*np.pi*247*k*v+.3)/k for k in range(1,6))
 pad=.065*np.sin(2*np.pi*220*t)+.025*np.sin(2*np.pi*881*t)
 instrumental=np.column_stack((pad+drums+pluck,pad*.7+drums*.6-pluck*.65))
 vocal=np.column_stack((voice,voice*.91))
 fade=np.minimum(1,np.maximum(0,(4-t)/.05))[:,None];instrumental*=fade;vocal*=fade
 u=np.maximum(t-.25,0)
 tail=(t>=.25)*.2*np.minimum(1,u/.003)*np.exp(-u/.5)*(np.sin(2*np.pi*307*u)+.5*np.sin(2*np.pi*3509*u))*fade[:,0]
 anti=pad+pluck
 scenes={'voice_mix':vocal+instrumental*.65,'voice_solo':vocal,'instrumental':instrumental,
         'percussion':np.column_stack((drums,drums*.6))*fade,'tail':np.column_stack((tail,tail*.7)),
         'antiphase':np.column_stack((anti,-anti))*fade,'quiet_noise':np.column_stack((noise,noise*.6))*.0001*fade,
         'silence':np.zeros((len(t),2)),'stress':(vocal+instrumental*.65)*3}
 for name,data in scenes.items():
  arr=np.asarray(data,dtype='<f4');raw=arr.tobytes();fname=f'{name}-{rate}.f32';(out/fname).write_bytes(raw)
  manifest.append({'file':fname,'rate':rate,'channels':2,'frames':len(t),'sha256':hashlib.sha256(raw).hexdigest(),'samplePeak':float(np.max(np.abs(arr)))})
(out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('PASS: 9 original synthetic stereo families x 2 rates, with voiced-like, fricative, instrumental, tail and stress signals.')
