#!/usr/bin/env python3
"""Check a public source distribution; never print matched credential values.

This is a guard against common accidental inclusions, not a complete secret audit.
"""
import argparse
import re
from pathlib import Path

IGNORED_DIRS = {'.git', '.build', 'build', '.swiftpm', '__pycache__'}
PRIVATE_NAMES = {'auth.json', 'credentials.json', 'state.json', 'alerts.json', 'custom-services.json', '.DS_Store'}
PRIVATE_DOCS = {'HANDOFF.md', 'START-HERE.md', 'REVIEW.md', 'current-status.md',
                'integration-validation.md', 'source-audit.md', 'planning-validation.json'}
PATTERNS = {
    'private-key': re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    'provider-key': re.compile(r'\bsk-(?:ant-|or-)?[A-Za-z0-9_-]{24,}'),
    'github-token': re.compile(r'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})'),
    'telegram-token': re.compile(r'\b[0-9]{8,12}:[A-Za-z0-9_-]{30,}'),
    'jwt': re.compile(r'\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{30,}\.[A-Za-z0-9_-]{20,}'),
    'personal-home': re.compile('/' + r'Users/(?!runner(?:/|\b)|user(?:/|\b)|test(?:/|\b)|me(?:/|\b))[^/\s"\']+/'),
}

def check(root: Path) -> list[str]:
    errors = []
    for path in sorted(root.rglob('*')):
        rel = path.relative_to(root)
        if any(part in IGNORED_DIRS or part.endswith('.xcodeproj') for part in rel.parts):
            continue
        if path.is_symlink():
            errors.append(f'{rel}: symlink is not permitted in distribution')
            continue
        if not path.is_file():
            continue
        if (path.name in PRIVATE_NAMES | PRIVATE_DOCS or path.name.startswith('.env')
                or path.suffix in {'.key', '.pem', '.p12', '.db', '.sqlite', '.log'}):
            errors.append(f'{rel}: private/runtime file')
        try:
            body = path.read_text(encoding='utf-8')
        except UnicodeError:
            if path.suffix != '.png':
                errors.append(f'{rel}: unexpected binary')
            continue
        for label, pattern in PATTERNS.items():
            for match in pattern.finditer(body):
                line = body.count('\n', 0, match.start()) + 1
                errors.append(f'{rel}:{line}: {label}')
    return errors

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', nargs='?', type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    errors = check(args.root.resolve())
    print('\n'.join(errors) if errors else 'OK: public source distribution checks passed')
    raise SystemExit(bool(errors))
