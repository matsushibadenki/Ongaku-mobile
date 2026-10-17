"""Independent FFmpeg reference; this is engineering validation, not certification."""
import json
import re
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
errors = []
for row in json.loads((root / "measurements.json").read_text()):
    result = subprocess.run([
        "ffmpeg", "-hide_banner", "-nostats", "-f", "f32le", "-ar", str(int(row["rate"])),
        "-ac", "2", "-i", str(root / row["file"]), "-af", "ebur128", "-f", "null", "-"
    ], check=True, capture_output=True, text=True)
    values = re.findall(r"I:\s+(-?[0-9.]+) LUFS", result.stderr)
    assert values, result.stderr
    reference = float(values[-1])
    error = abs(reference - row["lufs"])
    assert error < 0.12, (row, reference, error)
    errors.append(error)
print(f"PASS: {len(errors)} full-rate captures agree with FFmpeg ebur128 within 0.12 LU; maximum {max(errors):.6f} LU")
