"""Small real audio fixtures; no user music or network access required."""
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
for name in ['Tagged', 'Compilation', 'Other', 'Untagged/CD1', 'Untagged/CD2', 'Empty']:
    (root / name).mkdir(parents=True, exist_ok=True)

def run(*args):
    subprocess.run(['ffmpeg', '-v', 'error', *args, '-y'], check=True)

cover = root / 'cover.png'
run('-f', 'lavfi', '-i', 'color=c=orange:s=64x64', '-frames:v', '1', str(cover))
for ext, codec in [('mp3', 'libmp3lame'), ('m4a', 'aac'), ('flac', 'flac'), ('aiff', 'pcm_s16be'), ('wav', 'pcm_s16le')]:
    args = ['-f', 'lavfi', '-i', 'sine=frequency=440:duration=0.1']
    if ext != 'wav':
        args += ['-i', str(cover), '-map', '0:a', '-map', '1:v', '-c:v', 'copy', '-disposition:v:0', 'attached_pic']
    if ext == 'aiff':
        args += ['-write_id3v2', '1']
    args += ['-c:a', codec]
    for tag in ['title=Song Z', 'artist=Guest A', 'album=Collection', 'album_artist=Various Artists', 'track=2/12', 'disc=1/2']:
        args += ['-metadata', tag]
    run(*args, str(root / 'Tagged' / f'track.{ext}'))
(root / 'Tagged' / 'FOLDER.PNG').write_bytes(cover.read_bytes())
for filename, artist, number in [('10 B.mp3', 'Guest A', 10), ('2 A.mp3', 'Guest B', 2)]:
    run('-f', 'lavfi', '-i', 'sine=frequency=440:duration=0.1', '-c:a', 'libmp3lame',
        '-metadata', 'album=Mix', '-metadata', f'artist={artist}', '-metadata', f'track={number}/10',
        str(root / 'Compilation' / filename))
for name in ['Untagged/CD1/10.wav', 'Untagged/CD1/2.wav', 'Untagged/CD2/2.wav', 'Empty/none.wav']:
    run('-f', 'lavfi', '-i', 'sine=frequency=440:duration=0.1', '-c:a', 'pcm_s16le', str(root / name))
(root / 'Untagged' / 'Cover.PNG').write_bytes(cover.read_bytes())
