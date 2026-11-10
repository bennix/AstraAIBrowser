#!/usr/bin/env python3
"""Bundle local FFmpeg tools and their relocatable non-system Mach-O dependencies."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--destination', type=Path, required=True)
args = parser.parse_args()
root = args.destination.resolve()
lib = root / 'lib'
lib.mkdir(parents=True, exist_ok=True)
manifest = []
visited = {}

def output(*command):
    return subprocess.check_output(command, text=True)

def bundle(source, destination):
    source = source.resolve(strict=True)
    if source in visited:
        return visited[source]
    if destination in visited.values():
        raise RuntimeError(f'Conflicting dependency basename: {destination.name}')
    visited[source] = destination
    shutil.copy2(source, destination)
    destination.chmod(0o755)
    subprocess.run(['codesign', '--remove-signature', str(destination)], capture_output=True)
    manifest.append({'file': str(destination.relative_to(root)), 'source': str(source),
                     'sourceSHA256': hashlib.sha256(source.read_bytes()).hexdigest()})
    # Homebrew installs license notices and formula/source metadata in each keg.
    parts = source.parts
    if 'Cellar' in parts:
        index = parts.index('Cellar')
        keg = Path(*parts[:index + 3])
        notices = root / 'licenses' / (parts[index + 1] + '-' + parts[index + 2])
        notices.mkdir(parents=True, exist_ok=True)
        for entry in keg.iterdir():
            if entry.is_file() and entry.name.upper().startswith(('LICENSE', 'COPYING', 'COPYRIGHT', 'INSTALL_RECEIPT')):
                shutil.copy2(entry, notices / entry.name)
        if (keg / '.brew').exists():
            shutil.copytree(keg / '.brew', notices / 'formula', dirs_exist_ok=True)
    dependencies = [line.strip().split(' (compatibility version')[0]
                    for line in output('otool', '-L', str(source)).splitlines()[1:]]
    for dependency in dependencies:
        if dependency.startswith(('/usr/lib/', '/System/Library/')):
            continue
        candidate = Path(dependency)
        if dependency.startswith('@loader_path/'):
            candidate = source.parent / dependency.removeprefix('@loader_path/')
        if not candidate.is_absolute():
            raise RuntimeError(f'Unresolved dependency {dependency} in {source.name}')
        if candidate.resolve() == source:
            continue
        target = bundle(candidate, lib / candidate.name)
        relative = os.path.relpath(target, destination.parent)
        subprocess.run(['install_name_tool', '-change', dependency, '@loader_path/' + relative,
                        str(destination)], check=True, capture_output=True)
    if destination.suffix == '.dylib':
        subprocess.run(['install_name_tool', '-id', '@loader_path/' + destination.name,
                        str(destination)], check=True, capture_output=True)
    return destination

for tool in ['ffmpeg', 'ffprobe']:
    source = shutil.which(tool)
    if not source:
        raise SystemExit(f'{tool} is required on the build machine to create the self-contained bundle')
    bundle(Path(source), root / tool)
(root / 'ffmpeg-dependencies.json').write_text(json.dumps(manifest, indent=2) + '\n')
for binary in list(lib.glob('*.dylib')) + [root / 'ffmpeg', root / 'ffprobe']:
    subprocess.run(['codesign', '--force', '--sign', '-', str(binary)], check=True, capture_output=True)
for tool in ['ffmpeg', 'ffprobe']:
    subprocess.run([str(root / tool), '-version'], check=True, stdout=subprocess.DEVNULL)
print(f'Bundled FFmpeg tools and {len(visited) - 2} dependencies')
