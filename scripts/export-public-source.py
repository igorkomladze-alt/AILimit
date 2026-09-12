#!/usr/bin/env python3
"""Export an allowlisted, history-free source tree. Refuses an existing destination."""
import argparse
import shutil
from pathlib import Path

ROOT_FILES = ['.gitignore', 'Package.swift', 'project.yml', 'README.md', 'LICENSE',
              'THIRD_PARTY_NOTICES.md', 'CONTRIBUTING.md']
TREES = {'App': {'.swift', '.json', '.png', '.svg', '.plist'},
         'Sources': {'.swift'}, 'Tests': {'.swift'}, '.github': {'.yml'}}
FILES = ['scripts/package-app.sh', 'scripts/check-bundle.sh', 'scripts/check-privacy.sh',
         'scripts/render-icon.swift', 'scripts/check-distribution.py',
         'scripts/export-public-source.py', 'docs/service-logo-sources.md',
         'docs/provider-sources.md']

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    destination = args.destination.resolve()
    destination.mkdir(parents=True, exist_ok=False)
    paths = [root / name for name in ROOT_FILES + FILES]
    for directory, extensions in TREES.items():
        paths += [p for p in (root / directory).rglob('*') if p.is_file() and p.suffix in extensions
                  and not any(part in {'.build', 'build', '.git', '.swiftpm'} for part in p.relative_to(root).parts)]
    for source in paths:
        if source.is_symlink():
            raise SystemExit('Refusing symlink: ' + str(source.relative_to(root)))
        target = destination / source.relative_to(root)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    print(f'Exported {len(paths)} files to {destination}')
