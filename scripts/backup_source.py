#!/usr/bin/env python3
"""备份源代码与模型；不打包构建缓存、旧任务记录、Git数据库或签名产物。"""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument('destination', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
excluded = {'build', 'recovery', '.git', 'xcuserdata', '.DS_Store', '__pycache__'}
paths = sorted(p for p in root.rglob('*') if p.is_file() and not any(part in excluded for part in p.relative_to(root).parts))
args.destination.parent.mkdir(parents=True, exist_ok=True)
# 排他创建，已有备份不能被无意覆盖。
with zipfile.ZipFile(args.destination, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
    manifest = {}
    for path in paths:
        relative = path.relative_to(root).as_posix()
        data = path.read_bytes()
        archive.writestr('XiangqiCoach/' + relative, data)
        manifest[relative] = {'sha256': hashlib.sha256(data).hexdigest(), 'size': len(data)}
    archive.writestr('SOURCE_MANIFEST.json', json.dumps(manifest, ensure_ascii=False, indent=2))
with zipfile.ZipFile(args.destination) as archive:
    assert archive.testzip() is None
    for relative, entry in manifest.items():
        assert hashlib.sha256(archive.read('XiangqiCoach/' + relative)).hexdigest() == entry['sha256']
print(json.dumps({'backup': str(args.destination), 'files': len(paths), 'sha256': hashlib.sha256(args.destination.read_bytes()).hexdigest()}, ensure_ascii=False))
