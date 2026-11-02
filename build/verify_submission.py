"""Check the portable source distribution and its SHA-256 inventories."""
import argparse
import ast
import hashlib
import json
from pathlib import Path,PurePosixPath
import re
import zipfile

PARAMETER_SHA256='dc66425157588a3de922edcd26454e72f80da2047edf0c5dcbeb0c552a04d4d0'
SERVO_SHA256='93b11382b50aac89f29cc206d5e33ac130a19d03d6a3c59066b25d0f5bb2c37b'
FOLDERS={'src','sim','build','board','data','skill','report'}
EXCLUDE={'.Xil','__pycache__','.git','xsim.dir','.vivado_user_data'}


def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda:f.read(1024*1024),b''): h.update(block)
    return h.hexdigest()


def included(path,root):
    parts=path.relative_to(root).parts
    return not(set(parts)&EXCLUDE or parts[:2]==('build','workspace') or path.suffix=='.pyc')


def files(root):
    return {p.relative_to(root).as_posix():p for p in root.rglob('*') if p.is_file() and included(p,root)}


def check_manifest(path,require_complete=True):
    root=path.parent
    expected={}
    for line in path.read_text('utf-8-sig').splitlines():
        digest,name=line.split('  ',1)
        rel=PurePosixPath(name)
        if not re.fullmatch('[0-9a-f]{64}',digest) or rel.is_absolute() or '..' in rel.parts or name in expected:
            raise ValueError('Invalid checksum entry: '+name)
        p=root/name
        if not p.is_file() or p.is_symlink() or sha(p)!=digest:
            raise ValueError('Checksum mismatch: '+str(p))
        expected[name]=digest
    if require_complete:
        actual=set(files(root))-{path.name}
        if actual!=set(expected): raise ValueError('Checksum inventory differs: '+str(path))
    return len(expected)


def verify(root,archive=None):
    root=root.resolve()
    if {p.name for p in root.iterdir() if p.is_dir()}!=FOLDERS:
        raise ValueError('Expected src/sim/build/board/data/skill/report directories')
    required=['README.md','build/layout.json','build/prepare_project.py','build/package_checks.json',
        'src/TinyYOLO_192/linux/model_config.json','src/TinyYOLO_192/linux/Makefile',
        'src/TinyYOLO_192/linux/tinyyolo_dma.c','build/TinyYOLO_192/vivado/TinyYOLO_192.xpr',
        'board/TinyYOLO_192/firmware/final_192.bit','board/TinyYOLO_192/firmware/final_192.xsa',
        'board/TinyYOLO_192/firmware/final_192_routed.dcp',
        'board/TinyYOLO_192/firmware/baseline/board_verified_192.bit',
        'data/TinyYOLO_192/model/parameters.bin','src/pc_ui/bird_preview.py',
        'src/board_updates/camera_infer.py','src/video_demo/TinyYOLO_bird_UI_demo.mp4',
        'src/servo_pan_tilt/servo_pan_tilt_link.v','src/servo_calibration/servo_microtest.v',
        'skill/ross-rtl-pipeline-skill-2.2.0/skills/vivado-rtl-pipeline-design/SKILL.md',
        'report/技术报告文档.pdf','report/TinyYOLO_192_Bilingual_Poster.pptx']
    for name in required:
        if not (root/name).is_file(): raise FileNotFoundError(name)
    if sha(root/'data/TinyYOLO_192/model/parameters.bin')!=PARAMETER_SHA256:
        raise ValueError('Unexpected model parameters')
    if sha(root/'board/servo_pan_tilt/firmware/servo_pan_tilt_link.bit')!=SERVO_SHA256:
        raise ValueError('Unexpected dual-axis firmware')
    allfiles=files(root)
    for name,p in allfiles.items():
        if p.is_symlink(): raise ValueError('Symbolic link in distribution: '+name)
        if p.suffix=='.py': ast.parse(p.read_text('utf-8-sig'),filename=name)
        if p.suffix=='.json': json.loads(p.read_text('utf-8-sig'))
        if p.suffix=='.md':
            for link in re.findall(r'\[[^\]]*\]\(([^)]+)\)',p.read_text('utf-8-sig')):
                if re.match(r'https?://|#',link): continue
                target=link.split('#')[0]
                if target:
                    resolved=(p.parent/target).resolve()
                    if root not in resolved.parents or not resolved.exists():
                        raise ValueError('Broken/nonportable link: '+name+' -> '+target)
    identity=json.loads((root/'build/file_identity.json').read_text('utf-8'))
    for name,item in identity.items():
        if sha(root/name)!=item['submitted_sha256']: raise ValueError('Identity mismatch: '+name)
        if item['changed']!=(item['original_sha256']!=item['submitted_sha256']): raise ValueError('Invalid identity flag: '+name)
        if name.startswith(('board/TinyYOLO_192/firmware/','data/TinyYOLO_192/')) and item['changed']:
            raise ValueError('Frozen binary changed: '+name)
    hashed=check_manifest(root/'SHA256SUMS.txt')
    nested=0
    for p in root.rglob('SHA256SUMS.txt'):
        if p.parent!=root and included(p,root): nested+=check_manifest(p,require_complete=False)
    if archive:
        with zipfile.ZipFile(archive) as z:
            if z.testzip(): raise ValueError('ZIP CRC check failed')
            prefix='TinyYOLO_192_比赛提交包/'
            entries={i.filename:i for i in z.infolist() if not i.is_dir()}
            if len(entries)!=len(z.infolist()) or set(entries)!={prefix+n for n in allfiles}:
                raise ValueError('ZIP file list differs')
            for name,p in allfiles.items():
                if hashlib.sha256(z.read(entries[prefix+name])).hexdigest()!=sha(p): raise ValueError('ZIP differs: '+name)
    return dict(status='PASS',files=len(allfiles),sha256_entries=hashed,nested_sha256_entries=nested,
                model_input='192x192',historical_source_hashes_preserved=True,archive_verified=bool(archive))


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[1])
    ap.add_argument('--archive',type=Path)
    args=ap.parse_args()
    print(json.dumps(verify(args.root,args.archive),ensure_ascii=False,indent=2))
