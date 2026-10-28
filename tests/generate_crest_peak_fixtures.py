"""44.1-kHz bounded transient and phase variants; mobile uses 96-kHz prepared PCM."""
import json, hashlib, sys
from pathlib import Path
import numpy as np
from scipy.signal import resample_poly
root=Path(sys.argv[1]);root.mkdir(parents=True,exist_ok=True)
rate=44100;n=rate
x=np.arange(n); t=x/rate
base=.003*(np.sin(2*np.pi*137*t)+.5*np.sin(2*np.pi*281*t))
# Pairs of close, opposite-sign peaks stress reconstruction and peak detection.
for i in range(5000,n-1000,3971):
 base[i:i+4] += np.array([.98,-.72,.61,-.41]) * (1 if (i//3971)%2 else -1)
base*=.99/np.max(np.abs(base))
right=np.roll(base,7)*.8
stereo=np.stack([base,right],axis=1)
manifest=[]
for rate,pcm in [(44100,stereo),(96000,resample_poly(stereo,320,147,axis=0))]:
 data=np.asarray(pcm,dtype='<f4').tobytes();name=f'crest-{rate}.f32';(root/name).write_bytes(data)
 manifest.append({'name':name,'sampleRate':rate,'frames':len(pcm),'samplePeak':float(np.max(abs(pcm))),'rms':float(np.sqrt(np.mean(pcm**2))),'sha256':hashlib.sha256(data).hexdigest()})
(root/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('PASS 44.1-kHz original and polyphase-prepared 96-kHz stereo crest PCM')
