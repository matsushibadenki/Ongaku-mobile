"""Run prebuilt audit binaries; requires an explicitly supplied, dedicated Simulator.
Usage: python3 tests/run_transient_cost_samples.py WORKDIR DEVICE_UUID
WORKDIR contains mac-audit, fixtures and an installed local.ongaku.transient-cost-audit.
Build instructions and SDK metadata are recorded in the companion quality report.
"""
import json, shutil, subprocess, sys, time
from pathlib import Path
root=Path(sys.argv[1]); device=sys.argv[2]; bundle='local.ongaku.transient-cost-audit'
def call(*args,check=True):
 return subprocess.run(args,check=check,capture_output=True,text=True).stdout.strip()
container=Path(call('xcrun','simctl','get_app_container',device,bundle,'data'))/'Documents'
for platform in ['mac','ios']:
 dest=root/platform;dest.mkdir(exist_ok=True);(dest/'pcm').mkdir(exist_ok=True)
 for round in range(3):
  modes=['bare','off','default','max'];modes=modes[round:]+modes[:round]
  for mode in modes:
   name=f'{mode}-{round}'
   if platform=='mac':
    output=dest/name;output.mkdir(exist_ok=True)
    call(str(root/'mac-audit'),mode,str(output),str(root/'fixtures'),*(['pcm'] if round==0 else []))
   else:
    call('xcrun','simctl','terminate',device,bundle,check=False)
    for file in ['status.txt','result.json']:(container/file).unlink(missing_ok=True)
    call('xcrun','simctl','launch',device,bundle,mode,*(['pcm'] if round==0 else []))
    deadline=time.monotonic()+60
    while not (container/'status.txt').exists():
     if time.monotonic()>deadline:raise RuntimeError('audit timed out')
     time.sleep(.1)
    if (container/'status.txt').read_text()!='COMPLETE':raise RuntimeError((container/'status.txt').read_text())
    output=container
   shutil.copy2(output/'result.json',dest/f'{name}.json')
   if round==0:
    for file in (output/'pcm').glob('*.f32'):shutil.copy2(file,dest/'pcm'/file.name)
   print(platform,name,'COMPLETE',flush=True)
 call('xcrun','simctl','terminate',device,bundle,check=False)
call(str(root/'compare'),str(root/'mac/pcm'),str(root/'ios/pcm'),str(root/'fixtures'),str(root/'comparison'))
print('PASS: sample series and loudness comparison',flush=True)
