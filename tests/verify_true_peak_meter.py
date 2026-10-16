"""Independent FFmpeg ebur128 true-peak cross-check of the captured final PCM."""
import json, math, re, subprocess, sys
from pathlib import Path
root, report = Path(sys.argv[1]), Path(sys.argv[2])
files=sorted(root.glob('case-*.wav'),key=lambda p:int(p.stem.split('-')[-1]))
assert len(files)==84, len(files)
rows=[]
for file in files:
    process=subprocess.run(['ffmpeg','-hide_banner','-nostats','-i',str(file),'-af','ebur128=peak=true','-f','null','-'],capture_output=True,text=True,check=True)
    values=re.findall(r'Peak:\s+(-?[0-9.]+) dBFS',process.stderr)
    assert values, process.stderr
    peak=float(values[-1])
    assert math.isfinite(peak) and peak<=-1.0, (file.name,peak)
    rows.append({'case':file.stem,'truePeakDBFS':peak})
# Known intersample calibration: sample peak ~-2 dBFS, reconstructed amplitude 1.12.
calibration=subprocess.run(['ffmpeg','-hide_banner','-nostats','-f','lavfi','-i',
 "aevalsrc='1.12*sin(PI*n/2+PI/4)*min(1,min(n,9599-n)/512)':s=48000:d=0.2",'-af','ebur128=peak=true','-f','null','-'],capture_output=True,text=True,check=True)
calPeak=float(re.findall(r'Peak:\s+(-?[0-9.]+) dBFS',calibration.stderr)[-1])
assert abs(calPeak-20*math.log10(1.12))<0.2, calPeak
report.write_text(json.dumps({'meter':'FFmpeg ebur128 peak=true','version':subprocess.check_output(['ffmpeg','-version'],text=True).splitlines()[0],
 'calibrationPeakDBFS':calPeak,'maximumPeakDBFS':max(r['truePeakDBFS'] for r in rows),'cases':rows},indent=2)+'\n')
print(f"PASS: independent ebur128 true-peak check: {len(rows)} captures <= -1 dB; maximum {max(r['truePeakDBFS'] for r in rows)} dBFS, calibration {calPeak} dBFS")
