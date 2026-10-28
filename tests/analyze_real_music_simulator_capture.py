"""Derive aggregate values only; never store or emit the user's captured PCM."""
import json,re,sys
from pathlib import Path
import numpy as np
from scipy.signal import resample_poly
root=Path(sys.argv[1]);text=(root/'simulator-report.txt').read_text()
rate=int(float(re.search(r'OUTPUT rate=([\d.]+)',text).group(1)))
next_frame=int(re.search(r'NEXT frame=(\d+)',text).group(1))
raw=np.fromfile(root/'simulator-captured.f32',dtype='<f4').reshape(-1,2);assert np.isfinite(raw).all()
reconstructed=resample_poly(raw,16,1,axis=0);start=max(0,next_frame-int(.2*rate));end=min(len(raw),next_frame+int(.2*rate));local=raw[start:end]
def db(x):return 20*np.log10(max(float(x),1e-20))
record={'rate':rate,'frames':len(raw),'nextObservationFrame':next_frame,'nextObservationUncertainty':'UI polling plus audio-tap buffering; not the exact boundary','diagnosticObservation':re.search(r'firstDiagnosticFrame=(\w+)',text).group(1),'samplePeakDBFS':db(np.max(abs(raw))),'reconstructed16xDBFS':db(np.max(abs(reconstructed))),'nextWindowReconstructed16xDBFS':db(np.max(abs(reconstructed[start*16:end*16]))),'nextWindowMaxAdjacentStep':float(np.max(abs(np.diff(local,axis=0))))}
diagnostic=record['diagnosticObservation']
if diagnostic.isdigit():
 frame=int(diagnostic);lo=max(0,frame-int(.2*rate));hi=min(len(raw),frame+int(.2*rate))
 record['diagnosticWindowReconstructed16xDBFS']=db(np.max(abs(reconstructed[lo*16:hi*16])))
 record['diagnosticWindowMaxAdjacentStep']=float(np.max(abs(np.diff(raw[lo:hi],axis=0))))
match=re.search(r'UPGRADE frame=(\d+) diagnostics=(\w+)',text)
if match:
 frame=int(match.group(1));lo=max(0,frame-int(.2*rate));hi=min(len(raw),frame+int(.2*rate))
 record['upgradeObservationFrame']=frame;record['upgradeDiagnostics']=match.group(2)
 record['upgradeWindowReconstructed16xDBFS']=db(np.max(abs(reconstructed[lo*16:hi*16])))
 record['upgradeWindowMaxAdjacentStep']=float(np.max(abs(np.diff(raw[lo:hi],axis=0))))
(root/'simulator-peak-summary.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record,indent=2))
