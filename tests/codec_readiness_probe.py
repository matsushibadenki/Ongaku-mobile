"""Run each truncated decoder in an isolated process; never feed prefixes to the app."""
import json, subprocess, sys
from pathlib import Path
root, report = Path(sys.argv[1]), Path(sys.argv[2])
formats = [('mp3','libmp3lame',[]), ('m4a','aac',[]), ('fast.m4a','aac',['-movflags','+faststart']),
 ('flac','flac',[]), ('wav','pcm_s16le',[]), ('aif','pcm_s16be',[]), ('aiff','pcm_s16be',[]),
 ('caf','pcm_f32le',[]), ('aac','aac',['-f','adts']), ('alac','alac',['-f','ipod']), ('alac.m4a','alac',[])]
results=[]
for name, codec, extra in formats:
    full=root/f'full.{name}'
    subprocess.run(['ffmpeg','-v','error','-f','lavfi','-i',
      'aevalsrc=0.3*sin(2*PI*997*t)|0.2*sin(2*PI*12001*t):s=44100:d=2', '-c:a',codec,*extra,'-y',str(full)],check=True)
    data=full.read_bytes()
    for fraction in [1,0.1,0.5,0.9]:
        file=full if fraction==1 else root/f'prefix-{fraction}.{name}'
        if fraction!=1: file.write_bytes(data[:int(len(data)*fraction)])
        process=subprocess.run([str(root/'probe'),str(file)],capture_output=True,text=True,timeout=30)
        try: observed=json.loads(process.stdout.strip().splitlines()[-1])
        except (ValueError,IndexError): observed={'opened':False,'decoderExit':process.returncode}
        if fraction==1:
            assert observed.get('completedProbe') and observed.get('decodedFrames',0)>80000, (name,observed,process.stderr)
            assert len(observed.get('seekFrames',[]))==3 and all(n>0 for n in observed['seekFrames']), (name,observed)
        row={'format':name,'fraction':fraction,'bytes':file.stat().st_size,**observed}
        results.append(row)
        print(json.dumps(row,sort_keys=True),flush=True)
report.write_text(json.dumps({'policy':'complete immutable file required for every current codec', 'cases':results},indent=2)+'\n')
print(f'PASS: {len(formats)} complete files decode and seek; {len(formats)*3} prefix observations recorded in {report}')
