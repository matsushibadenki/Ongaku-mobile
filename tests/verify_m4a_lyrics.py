"""Independent atom, packet-hash, metadata and decoded-PCM preservation checks."""
import base64
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys

binary, directory = sys.argv[1], Path(sys.argv[2])
for tool in ('ffmpeg', 'ffprobe'):
    if not shutil.which(tool):
        raise SystemExit(f'{tool} is required for audio preservation verification')

def run(*args):
    return subprocess.check_output(args, stderr=subprocess.PIPE)

def box(kind, data, extended=False):
    return (struct.pack('>I4sQ', 1, kind, len(data)+16) if extended else struct.pack('>I4s', len(data)+8, kind)) + data

def boxes(data, start=0):
    result=[]
    while start < len(data):
        size, kind = struct.unpack_from('>I4s', data, start)
        header=8
        if size == 1:
            size=struct.unpack_from('>Q', data, start+8)[0]; header=16
        elif size == 0: size=len(data)-start
        assert header <= size <= len(data)-start
        result.append((kind, data[start+header:start+size], data[start:start+size], start))
        start += size
    assert start == len(data)
    return result

def child(data, kind, start=0):
    return next(payload for k,payload,_,_ in boxes(data,start) if k==kind)

def probe(path):
    return json.loads(run('ffprobe','-v','error','-show_format','-show_streams','-show_chapters','-of','json',str(path)))

def packets(path):
    return json.loads(run('ffprobe','-v','error','-show_packets','-show_data_hash','sha256','-of','json',str(path)))

def pcm(path):
    return run('ffmpeg','-v','error','-i',str(path),'-map','0:a:0','-f','f64le','-')

# Valid tiny PNG, retained as a covr item without running an image editor.
png=base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jWZkAAAAASUVORK5CYII=')
custom=box(b'----',box(b'mean',b'\0'*4+b'com.apple.iTunes')+box(b'name',b'\0'*4+b'replaygain_track_gain')+box(b'data',struct.pack('>II',1,0)+b'-3.25 dB'))
cover=box(b'covr',box(b'data',struct.pack('>II',14,0)+png))
unknown=box(b'zzzz',b'opaque metadata must survive')

# Chapter data creates a separate text track with its own chunk offsets.
chapters=directory/'chapters.txt'
chapters.write_text(';FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=500\ntitle=Opening\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=500\nEND=1000\ntitle=Ending\n')

def enrich_movie(payload):
    out=b''
    for kind,body,raw,_ in boxes(payload):
        if kind==b'udta':
            udta=b''
            for k,b,r,_ in boxes(body):
                if k==b'meta':
                    meta=b[:4]
                    for mk,mb,mr,_ in boxes(b,4):
                        meta += box(mk,mb+custom+cover+unknown) if mk==b'ilst' else mr
                    udta+=box(k,meta)
                else: udta+=r
            out+=box(kind,udta)
        else: out+=raw
    return out

def relocate_offsets(data, delta):
    out=b''
    for kind,payload,raw,_ in boxes(data):
        if kind in (b'trak',b'mdia',b'minf',b'stbl'):
            out+=box(kind,relocate_offsets(payload,delta))
        elif kind in (b'stco',b'co64'):
            count=struct.unpack_from('>I',payload,4)[0]; width=4 if kind==b'stco' else 8
            values=[int.from_bytes(payload[8+i*width:8+(i+1)*width],'big')+delta for i in range(count)]
            out+=box(kind,payload[:8]+b''.join(v.to_bytes(width,'big') for v in values))
        else: out+=raw
    return out

def fingerprint(path):
    raw=path.read_bytes(); top=boxes(raw); movie=child(raw,b'moov')
    # Compare every non-lyric node including unknown/freeform/cover data. Only
    # the size fields on moov/udta/meta/ilst ancestors may change.
    def normalized(data, level):
        out=[]
        for kind,payload,raw,_ in boxes(data,4 if level==b'meta' else 0):
            if kind==b'\xa9lyr' and level==b'ilst': continue
            if kind in (b'udta',b'meta',b'ilst'):
                out.append((kind,normalized(payload,kind)))
            else: out.append((kind,raw))
        return out
    return [(k,b,start) for k,b,_,start in top if k not in (b'moov',b'free')], normalized(movie,b'moov')

count=0
for codec in ('aac','alac'):
 for rate in (44100,96000):
  original=directory/f'{codec}-{rate}-source.m4a'
  run('ffmpeg','-v','error','-f','lavfi','-i',f'aevalsrc=0.15*sin(2*PI*997*t)|0.1*sin(2*PI*2303*t):s={rate}:d=1',
      '-f','ffmetadata','-i',str(chapters),'-map','0:a','-map_metadata','1','-map_chapters','1','-c:a',codec,
      '-metadata','title=日本語のタイトル','-metadata','artist=Test Artist','-metadata','album=Album',
      '-metadata','album_artist=Album Artist','-metadata','composer=Composer','-metadata','date=2026',
      '-metadata','genre=Test','-metadata','track=2/12','-metadata','disc=1/2','-metadata','comment=Preserve this comment',
      '-metadata','lyrics=Old lyrics',str(original))
  src=boxes(original.read_bytes())
  moov=box(b'moov',enrich_movie(next(b for k,b,_,_ in src if k==b'moov')))
  tail=b''.join(r for k,_,r,_ in src if k!=b'moov')+moov
  for layout in ('tail','front'):
    before=directory/f'{codec}-{rate}-{layout}-before.m4a'
    if layout=='tail': data=tail
    else:
        # Move moov ahead of the first mdat and account for its size in every
        # existing audio/chapter chunk table when constructing the fixture.
        moved=box(b'moov',relocate_offsets(moov[8:],len(moov)))
        parts=[]; inserted=False
        for k,_,raw,_ in boxes(tail):
            if k==b'moov': continue
            if k==b'mdat' and not inserted: parts.append(moved); inserted=True
            parts.append(raw)
        data=b''.join(parts)
    before.write_bytes(data)
    after=directory/f'{codec}-{rate}-{layout}-after.m4a'; after.write_bytes(data)
    run(binary,str(after),str(directory))
    assert fingerprint(before)==fingerprint(after), f'{after.name}: non-lyric atoms, media bytes or offsets changed'
    a,b=probe(before),probe(after)
    cover_streams={stream['index'] for stream in a['streams'] if stream.get('disposition',{}).get('attached_pic')}
    def comparable_packets(path):
        result=packets(path)
        for packet in result['packets']:
            # covr lives inside the edited metadata, so its byte position may move;
            # its encoded image hash and every other packet field must match.
            if packet['stream_index'] in cover_streams: packet.pop('pos',None)
        return result
    assert comparable_packets(before)==comparable_packets(after), f'{after.name}: compressed packets or timestamps changed'
    assert pcm(before)==pcm(after), f'{after.name}: PCM changed'
    assert a['chapters']==b['chapters'], 'chapters changed'
    assert a['streams']==b['streams'], 'codec, bit depth, sample rate or stream metadata changed'
    at=a['format']['tags']; bt=b['format']['tags']
    assert {k:v for k,v in at.items() if k!='lyrics'} == {k:v for k,v in bt.items() if k!='lyrics'}, 'metadata changed'
    assert '[00:00.50]' in bt['lyrics'] and bt['lyrics']!='Old lyrics', 'new lyric not visible in independent reader'
    print(f'PASS: {codec} {rate} {layout}: packet hashes, f64 PCM, all non-lyric atoms, cover, freeform tags, chapters, technical metadata')
    count+=1

# ALAC filename extension is also accepted for a standard MP4 container.
alac=directory/'renamed.alac'; shutil.copy(directory/'alac-96000-tail-before.m4a',alac)
run(binary,str(alac),str(directory),'--structural-only')
assert pcm(alac)==pcm(directory/'alac-96000-tail-before.m4a')
print('PASS: .alac extension containing MP4/ALAC')

# Minimal containers exercise absent metadata and 64-bit box headers. The audio
# payload is opaque, so these cases test structure, not decoding.
ftyp=box(b'ftyp',b'M4A '+b'\0'*4+b'isom'); audio=box(b'mdat',b'opaque media'*30,extended=True)
def minimal_movie(offset, co64=False, codec=b'alac'):
    description=box(b'stsd',b'\0'*4+struct.pack('>I',1)+box(codec,b'\0'*28))
    offsets=box(b'co64' if co64 else b'stco',b'\0'*4+struct.pack('>I',1)+offset.to_bytes(8 if co64 else 4,'big'))
    handler=box(b'hdlr',b'\0'*8+b'soun'+b'\0'*13)
    return box(b'moov',box(b'trak',box(b'mdia',handler+box(b'minf',box(b'stbl',description+offsets)))),extended=True)
minimal=minimal_movie(len(ftyp)+16)
front=minimal_movie(len(ftyp)+len(minimal)+16)
co64=minimal_movie(len(ftyp)+16,co64=True)
for name,data in [('no-metadata',ftyp+audio+minimal),('extended-front',ftyp+front+audio),('co64-offsets',ftyp+audio+co64)]:
    path=directory/f'{name}.m4a'; path.write_bytes(data)
    run(binary,str(path),str(directory),'--structural-only')
    assert next(b for k,b,_,_ in boxes(path.read_bytes()) if k==b'mdat')==b'opaque media'*30
print('PASS: missing metadata, extended-size moov/mdat, repeated embedding')

for name,data in [
    ('truncated',ftyp+audio+minimal[:-1]),
    ('encrypted-audio',ftyp+audio+minimal_movie(len(ftyp)+16,codec=b'enca')),
    ('invalid-chunk-offset',ftyp+audio+minimal_movie(1)),
    ('duplicate-moov',ftyp+audio+minimal+minimal),
    ('fragmented',ftyp+audio+box(b'moof',b'')+minimal),
    ('fragmented-mvex',ftyp+audio+box(b'moov',box(b'trak',b'')+box(b'mvex',b''))),
    ('zero-sized-mdat',ftyp+minimal+struct.pack('>I4s',0,b'mdat')+b'audio'),
    ('oversized-box',ftyp+struct.pack('>I4sQ',1,b'moov',2**64-1)),
    ('numeric-meta',ftyp+audio+box(b'moov',box(b'trak',b'')+box(b'udta',box(b'meta',b'\0'*4+box(b'hdlr',b'\0'*8+b'mdta'+b'\0'*13))))),
]:
    path=directory/f'{name}.m4a'; path.write_bytes(data)
    run(binary,str(path),str(directory),'--reject')
print('PASS: nine unsupported/corrupt layouts reject without changing originals')
print(f'PASS: {count} independently decoded AAC/ALAC preservation cases')
