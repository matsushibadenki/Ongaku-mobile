import sys
from pathlib import Path
s=Path(sys.argv[1]).read_text();start=s.index('enum CrossfadePolicy {');end=s.index('\nenum LoudnessNormalizationMode:',start)
Path(sys.argv[2]).write_text('import Foundation\n'+s[start:end]+'\n')
