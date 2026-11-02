"""Assemble the portable project layout without modifying the submitted sources."""
import argparse
import json
from pathlib import Path
import shutil

TEXT_EXTENSIONS = {'.py','.ps1','.tcl','.xdc','.xpr','.xml','.v','.sv','.vh','.svh',
                   '.json','.txt','.md','.rpt','.log','.sh','.bat','.cmd','.c','.h',
                   '.bd','.xci','.prj','.vds','.rpx','.dts','.f','.str','.rdi'}


def prepare(package, project, output):
    package = package.resolve()
    output = output.resolve()
    layout = json.loads((package/'build/layout.json').read_text('utf-8'))[project]
    # Refuse overwriting arbitrary folders or the source distribution itself.
    for source, _ in layout:
        path = (package/source).resolve()
        if package not in path.parents:
            raise ValueError('Input is outside the distribution: '+source)
        if output == path or output in path.parents or path in output.parents:
            raise ValueError('Workspace overlaps submitted inputs: '+str(output))
    marker = output/'.project_workspace.json'
    if output.exists() and any(output.iterdir()):
        if not marker.is_file():
            raise ValueError('Choose an empty output folder: '+str(output))
        identity = json.loads(marker.read_text('utf-8'))
        if identity != {'project': project, 'package': str(package)}:
            raise ValueError('Workspace belongs to another project or distribution')
    output.mkdir(parents=True, exist_ok=True)
    count=0
    for source, destination in layout:
        origin = package/source
        if not origin.exists():
            raise FileNotFoundError(origin)
        files = list(origin.rglob('*')) if origin.is_dir() else [origin]
        for path in files:
            if not path.is_file():
                continue
            relative = path.relative_to(origin) if origin.is_dir() else Path()
            target = (output/destination/relative).resolve()
            if output not in target.parents:
                raise ValueError('Destination is outside the workspace: '+str(target))
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path,target)
            # Paths in Vivado's saved launch scripts must use this workspace.
            if target.suffix.lower() in TEXT_EXTENSIONS:
                try: text = target.read_text('utf-8-sig')
                except UnicodeError: continue
                if '__PROJECT_ROOT__' in text:
                    target.write_text(text.replace('__PROJECT_ROOT__',output.as_posix()),'utf-8')
            count+=1
    marker.write_text(json.dumps({'project': project, 'package': str(package)},indent=2)+'\n','utf-8')
    return {'project':project,'files':count,'workspace':str(output)}


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--project', choices=['TinyYOLO_192','servo_pan_tilt','servo_calibration'],default='TinyYOLO_192')
    ap.add_argument('--output',type=Path)
    args=ap.parse_args()
    package=Path(__file__).resolve().parents[1]
    output=args.output or package/'build/workspace'/args.project
    print(json.dumps(prepare(package,args.project,output),ensure_ascii=False,indent=2))
