"""Deterministic, original synthetic PCM. No personal/library audio is used."""
import array, hashlib, json, math, sys
from pathlib import Path
out=Path(sys.argv[1]);out.mkdir(parents=True,exist_ok=True)
scenes=['steady','percussion','pluck','tail','stereo_mix','antiphase','quiet_noise','silence']
manifest=[]
for rate in [48000,96000]:
 for scene in scenes:
  pcm=array.array('f');seed=47
  for i in range(rate*4):
   t=i/rate;seed=(1664525*seed+1013904223)&0xffffffff
   noise=((seed>>8)/8388608-1)
   pad=.12*math.sin(2*math.pi*220*t)+.04*math.sin(2*math.pi*881*t)
   hit=0.;pluck=0.;tail=0.
   for onset in ([.25+.5*k for k in range(8)] if scene in ['percussion','pluck','stereo_mix','antiphase'] else []):
    u=t-onset
    if 0<=u<.35:
     if scene in ['percussion','stereo_mix']: hit+=.45*math.exp(-u/0.012)*noise+.22*math.exp(-u/.08)*math.sin(2*math.pi*73*u)
     if scene in ['pluck','stereo_mix','antiphase']: pluck+=sum(.24/k*math.exp(-u*(6+k*2))*math.sin(2*math.pi*247*k*u+.4) for k in range(1,7))
   if scene=='tail' and t>=.25:
    u=t-.25
    tail=.3*min(1,u/.003)*math.exp(-u/0.65)*sum(math.sin(2*math.pi*f*u+.3*k)/(k+1) for k,f in enumerate([307,1103,3509,8009]))
   fade=min(1,t/.05)
   if scene=='steady':left=pad*fade;right=-.5*left
   elif scene=='percussion':left=hit;right=-.5*left
   elif scene=='pluck':left=pluck;right=-.5*left
   elif scene=='tail':left=tail;right=-.5*left
   elif scene=='stereo_mix':left=pad*fade+hit*.4+pluck*.3;right=pad*.6*fade+hit*.25-pluck*.4
   elif scene=='antiphase':left=(pad*fade+pluck*.3);right=-left
   elif scene=='quiet_noise':left=noise*.0001;right=-.5*left
   else:left=right=0.
   endFade=min(1,max(0,(4-t)/.05))
   pcm.extend([left*endFade,right*endFade])
  if sys.byteorder!='little':pcm.byteswap()
  data=pcm.tobytes();name=f'{scene}-{rate}.f32';(out/name).write_bytes(data)
  manifest.append(dict(file=name,rate=rate,channels=2,frames=rate*4,sha256=hashlib.sha256(data).hexdigest()))
(out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('Generated 8 synthetic stereo families x 2 rates, 4 seconds each.')
