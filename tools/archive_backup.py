"""Create, verify and restore a private car archive backup outside version control.

No command edits the source archive. Creation and restore refuse an existing destination.
Use fully downloaded files and pause other writers while creating a backup.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath


class BackupError(Exception):
    pass


def inventory(root: Path) -> tuple[list[str], dict[str, tuple[int, int, int]]]:
    directories, files = [], {}
    if root.is_symlink() or not root.is_dir():
        raise BackupError("The source must be an existing directory, not a symbolic link.")
    def walk(folder: Path):
        for path in sorted(folder.iterdir()):
            relative = path.relative_to(root).as_posix()
            info = path.lstat()
            if path.name.startswith('.') and path.name.endswith('.icloud'):
                raise BackupError("Some iCloud files are not downloaded. Keep the archive downloaded and retry.")
            if stat.S_ISLNK(info.st_mode):
                raise BackupError("The source contains symbolic links; no backup was published.")
            if stat.S_ISDIR(info.st_mode):
                directories.append(relative)
                walk(path)
            elif stat.S_ISREG(info.st_mode):
                files[relative] = (info.st_size, info.st_mtime_ns, info.st_ino)
            else:
                raise BackupError("The source contains an unsupported file type.")
    walk(root)
    return directories, files


def outside_git(path: Path):
    for parent in [path, *path.parents]:
        bare = (parent / 'HEAD').is_file() and (parent / 'objects').is_dir() and (parent / 'config').is_file()
        if (parent / '.git').exists() or bare:
            raise BackupError("Keep backups and restored personal archives outside every Git checkout or bare repository.")


def destination_for(value: Path, source: Path) -> Path:
    if value.is_symlink() or value.exists():
        raise BackupError("The destination already exists; choose a new folder.")
    destination = value.resolve()
    if destination.is_relative_to(source) or source.is_relative_to(destination):
        raise BackupError("Source and destination must be separate, non-nested locations.")
    outside_git(destination)
    return destination


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def copy_checked(source: Path, destination: Path, expected: dict | None = None) -> dict:
    before = source.lstat()
    if not stat.S_ISREG(before.st_mode):
        raise BackupError("A source file changed type while copying.")
    descriptor = os.open(source, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise BackupError("The source changed while copying. Pause other writers and retry.")
        destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        h, size = hashlib.sha256(), 0
        with os.fdopen(descriptor, 'rb', closefd=False) as src, destination.open('xb') as dst:
            os.chmod(destination, 0o600)
            for chunk in iter(lambda: src.read(1024 * 1024), b''):
                dst.write(chunk)
                h.update(chunk)
                size += len(chunk)
        after = source.lstat()
        if size != before.st_size:
            raise BackupError("A source file could not be fully read; no backup was published.")
        if (before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_ino, after.st_size, after.st_mtime_ns):
            raise BackupError("The source changed while copying. Pause other writers and retry.")
        record = {'size': size, 'sha256': h.hexdigest(), 'mtime_ns': before.st_mtime_ns}
        if expected and (record['size'], record['sha256']) != (expected['size'], expected['sha256']):
            raise BackupError("A backup file failed checksum verification during restore.")
        os.utime(destination, ns=(before.st_atime_ns, expected['mtime_ns'] if expected else before.st_mtime_ns))
        return record
    finally:
        os.close(descriptor)


def safe_relative(value) -> str:
    if not isinstance(value, str) or not value or '\\' in value or '\x00' in value:
        raise BackupError("The backup manifest contains an invalid relative path.")
    path = PurePosixPath(value)
    if path.is_absolute() or any(part in {'', '.', '..'} for part in value.split('/')):
        raise BackupError("The backup manifest contains an unsafe relative path.")
    return value


def load_manifest(backup: Path) -> dict:
    if backup.is_symlink() or (backup / 'manifest.json').is_symlink():
        raise BackupError("Symbolic links are not valid backup locations.")
    try:
        manifest = json.loads((backup / 'manifest.json').read_text())
        if manifest['schema'] != 1 or not isinstance(manifest['files'], list) or not isinstance(manifest['directories'], list):
            raise ValueError()
        names = set()
        for name in manifest['directories']:
            name = safe_relative(name)
            if name in names:
                raise ValueError()
            names.add(name)
        for record in manifest['files']:
            name = safe_relative(record['path'])
            if name in names or type(record['size']) is not int or record['size'] < 0 \
                    or type(record['mtime_ns']) is not int or record['mtime_ns'] < 0 \
                    or not isinstance(record['sha256'], str) or not re.fullmatch('[0-9a-f]{64}', record['sha256']):
                raise ValueError()
            names.add(name)
        return manifest
    except (OSError, ValueError, KeyError, TypeError):
        raise BackupError("The backup manifest is missing or invalid.") from None


def verify_tree(root: Path, manifest: dict) -> dict:
    directories, files = inventory(root)
    expected = {record['path']: record for record in manifest['files']}
    if set(directories) != set(manifest['directories']) or set(files) != set(expected):
        raise BackupError("The backup has missing or unexpected archive files or directories.")
    for name, record in expected.items():
        if files[name][0] != record['size'] or digest(root / name) != record['sha256']:
            raise BackupError("A backup file does not match its checksum.")
    return {'files': len(expected), 'bytes': sum(record['size'] for record in expected.values())}


def verify(backup: Path) -> dict:
    return verify_tree(backup / 'i20_book', load_manifest(backup))


def staging_for(destination: Path) -> Path:
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = destination.with_name('.' + destination.name + '.partial-' + uuid.uuid4().hex)
    staging.mkdir(mode=0o700)
    return staging


def publish(staging: Path, destination: Path):
    if destination.exists() or destination.is_symlink():
        raise BackupError("The destination appeared while copying; it was not replaced.")
    staging.rename(destination)


def create(source: Path, output: Path) -> dict:
    if source.name != 'i20_book' or source.is_symlink():
        raise BackupError("Select the actual i20_book directory, not a link or its parent.")
    source = source.resolve()
    destination = destination_for(output, source)
    directories, before = inventory(source)
    if not any((source / name).is_dir() for name in ('raw', 'log')):
        raise BackupError("The selected archive has neither raw nor log records.")
    staging = staging_for(destination)
    try:
        copied = staging / 'i20_book'
        copied.mkdir(mode=0o700)
        for name in directories:
            (copied / name).mkdir(parents=True, exist_ok=True, mode=0o700)
        records = [{'path': name, **copy_checked(source / name, copied / name)} for name in before]
        if inventory(source) != (directories, before):
            raise BackupError("The archive changed during backup. Pause other writers and retry.")
        # A second content pass also detects ordinary same-size changes before publication.
        if any(digest(source / record['path']) != record['sha256'] for record in records) or inventory(source) != (directories, before):
            raise BackupError("The archive changed during backup. Pause other writers and retry.")
        manifest = {'schema': 1, 'created_utc': datetime.now(timezone.utc).isoformat(),
                    'directories': directories, 'files': records}
        (staging / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        result = verify(staging)
        publish(staging, destination)
        return result
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def restore(backup: Path, output: Path) -> dict:
    if output.name != 'i20_book':
        raise BackupError("Restore to a new directory named i20_book.")
    # Validate links before resolving: resolving first would hide a linked backup root.
    result = verify(backup)
    backup = backup.resolve()
    destination = destination_for(output, backup)
    manifest = load_manifest(backup)
    staging = staging_for(destination)
    try:
        for name in manifest['directories']:
            (staging / name).mkdir(parents=True, exist_ok=True, mode=0o700)
        for record in manifest['files']:
            copy_checked(backup / 'i20_book' / record['path'], staging / record['path'], expected=record)
        verify_tree(staging, manifest)
        publish(staging, destination)
        return result
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    make = commands.add_parser('create')
    make.add_argument('--book', type=Path, required=True)
    make.add_argument('--out', type=Path, required=True)
    check = commands.add_parser('verify')
    check.add_argument('--backup', type=Path, required=True)
    recover = commands.add_parser('restore')
    recover.add_argument('--backup', type=Path, required=True)
    recover.add_argument('--out', type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        result = create(args.book, args.out) if args.command == 'create' else \
            restore(args.backup, args.out) if args.command == 'restore' else verify(args.backup)
        print(json.dumps({'ok': True, **result}))
        return 0
    except (BackupError, OSError) as error:
        # Do not include personal source/destination paths in routine diagnostics.
        print(str(error) if isinstance(error, BackupError) else 'The file operation failed; check permissions and available space.', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
