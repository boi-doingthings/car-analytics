"""Check the proposed tracked tree (or tracked files) without printing sensitive matches.

This is a heuristic guard, not a full secret scanner or an anonymity guarantee.
"""
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def violations(name, data):
    issues = []
    p = Path(name)
    if (name.startswith(('data/', 'tests/golden/', 'i20_book/'))
        or p.suffix.lower() in {'.csv', '.jpg', '.jpeg', '.pdf', '.p12', '.p8', '.pem', '.mobileprovision', '.ipa', '.db'}
        or name in {'service_log.json', '.env'} or '.local.' in name
        or (p.name.startswith('.env.') and p.name != '.env.example')):
        issues.append('private input or artifact')
    if b'\x00' in data:
        return issues  # Binary content requires separate manual review.
    text = data.decode('utf-8', errors='replace')
    patterns = {
        'personal absolute path': r'(?:/Users/|/home/|[A-Z]:\\Users\\)[A-Za-z0-9_.-]+',
        'private signing team': r'DEVELOPMENT_TEAM\s*:\s*[A-Z0-9]{10}',
        'private key': r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
        'token': r'\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[A-Z0-9]{16})\b',
        'personal email': r'\b[A-Za-z0-9._%+-]+@(?:gmail\.com|nvidia\.com|outlook\.com|icloud\.com)\b',
    }
    for label, pattern in patterns.items():
        if re.search(pattern, text): issues.append(label)
    # Authorization/stamp material may exist only in the explicitly invented test configuration.
    for line in text.splitlines():
        if re.search(r'(?:basicAuthorization|cfbBase64):\s*"[^"\n]+"', line):
            if not all(v in {'Basic dGVzdDp0ZXN0', 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'}
                       for v in re.findall(r'(?:basicAuthorization|cfbBase64):\s*"([^"\n]+)"', line)):
                issues.append('embedded provider authorization')
    return issues


def main():
    paths = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0')
    failed = []
    for name in filter(None, paths):
        p = ROOT / name
        if p.is_symlink(): failed.append((name, ['symlink requires manual review']))
        elif p.is_file():
            found = violations(name, p.read_bytes())
            if found: failed.append((name, found))
    for name, found in failed:
        print(f'{name}: {", ".join(found)}')
    print(f'Publication scan: {len(failed)} flagged files')
    return bool(failed)


if __name__ == '__main__':
    raise SystemExit(main())
