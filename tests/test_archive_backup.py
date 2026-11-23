"""Private-archive backup correctness, using invented records only."""
import importlib.util
import json
import os
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('archive_backup', ROOT / 'tools/archive_backup.py')
backup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backup)


@pytest.fixture
def book(tmp_path):
    root = tmp_path / 'source' / 'i20_book'
    for name, body in {'raw/days/example/20260101.json': '{"synthetic":true}',
                       'log/refuels/example.json': '{"amount":1000}',
                       'log/services/example/photo.jpg': 'invented image bytes'}.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body)
        os.utime(path, ns=(1760000000000000000, 1760000000000000000))
    (root / 'log/maintenance').mkdir()
    return root


def snapshot(root):
    return {str(p.relative_to(root)): (p.read_bytes(), p.stat().st_mtime_ns)
            for p in root.rglob('*') if p.is_file()}


def test_backup_verify_and_restore_preserve_bytes_mtimes_and_source(book, tmp_path):
    before = snapshot(book)
    output = tmp_path / 'backup'
    result = backup.create(book, output)
    assert result['files'] == 3
    assert backup.verify(output) == result
    assert snapshot(book) == before
    restored = tmp_path / 'restored/i20_book'
    assert backup.restore(output, restored) == result
    assert snapshot(restored) == before
    assert (restored / 'log/maintenance').is_dir()
    assert str(book) not in (output / 'manifest.json').read_text()


def test_tampered_or_extra_files_are_detected_and_cannot_be_restored(book, tmp_path):
    output = tmp_path / 'backup'
    backup.create(book, output)
    (output / 'i20_book/log/refuels/example.json').write_text('modified')
    with pytest.raises(backup.BackupError, match='checksum'):
        backup.verify(output)
    restored = tmp_path / 'restored/i20_book'
    with pytest.raises(backup.BackupError):
        backup.restore(output, restored)
    assert not restored.exists()


def test_extra_files_cannot_hide_outside_the_manifest(book, tmp_path):
    output = tmp_path / 'backup'
    backup.create(book, output)
    (output / 'i20_book/extra.json').write_text('{}')
    with pytest.raises(backup.BackupError, match='unexpected'):
        backup.verify(output)


def test_cloud_placeholders_and_links_cannot_silently_disappear(book, tmp_path):
    placeholder = book / 'log/refuels/.waiting.json.icloud'
    placeholder.touch()
    with pytest.raises(backup.BackupError, match='not downloaded'):
        backup.create(book, tmp_path / 'backup')
    placeholder.unlink()
    (book / 'log/link').symlink_to(tmp_path)
    with pytest.raises(backup.BackupError, match='symbolic'):
        backup.create(book, tmp_path / 'backup')
    assert not (tmp_path / 'backup').exists()


def test_existing_and_nested_destinations_are_never_overwritten(book, tmp_path):
    existing = tmp_path / 'existing'
    existing.mkdir()
    (existing / 'keep').write_text('preserved')
    with pytest.raises(backup.BackupError, match='already exists'):
        backup.create(book, existing)
    with pytest.raises(backup.BackupError, match='non-nested'):
        backup.create(book, book / 'backup')
    assert (existing / 'keep').read_text() == 'preserved'


def test_personal_backups_are_refused_inside_any_git_checkout(book, tmp_path):
    repository = tmp_path / 'another-repository'
    (repository / '.git').mkdir(parents=True)
    with pytest.raises(backup.BackupError, match='outside every Git'):
        backup.create(book, repository / 'backup')


def test_source_changes_abort_without_publishing_partial_backup(book, tmp_path, monkeypatch):
    original = backup.copy_checked
    changed = False
    def changing_source(source, destination, expected=None):
        nonlocal changed
        result = original(source, destination, expected)
        if not changed:
            changed = True
            (book / 'new.json').write_text('{"arrived_during_backup":true}')
        return result
    monkeypatch.setattr(backup, 'copy_checked', changing_source)
    with pytest.raises(backup.BackupError, match='changed'):
        backup.create(book, tmp_path / 'backup')
    assert not (tmp_path / 'backup').exists()
    assert not list(tmp_path.glob('.backup.partial-*'))


def test_unsafe_manifest_paths_are_rejected_before_restore(book, tmp_path):
    output = tmp_path / 'backup'
    backup.create(book, output)
    manifest = json.loads((output / 'manifest.json').read_text())
    manifest['files'][0]['path'] = '../escape.json'
    (output / 'manifest.json').write_text(json.dumps(manifest))
    with pytest.raises(backup.BackupError, match='unsafe'):
        backup.restore(output, tmp_path / 'restored/i20_book')
    assert not (tmp_path / 'escape.json').exists()


def test_cli_output_does_not_echo_private_paths(book, tmp_path, capsys):
    assert backup.main(['create', '--book', str(book), '--out', str(tmp_path / 'backup')]) == 0
    assert str(book) not in capsys.readouterr().out
    assert backup.main(['create', '--book', str(book), '--out', str(tmp_path / 'backup')]) == 1
    assert str(book) not in capsys.readouterr().err


def test_bare_git_repositories_are_refused_for_backup_and_restore(book, tmp_path):
    import subprocess
    repository = tmp_path / 'bare.git'
    subprocess.run(['git', 'init', '--bare', str(repository)], check=True, capture_output=True)
    with pytest.raises(backup.BackupError, match='outside every Git'):
        backup.create(book, repository / 'private-backup')
    output = tmp_path / 'backup'
    backup.create(book, output)
    with pytest.raises(backup.BackupError, match='outside every Git'):
        backup.restore(output, repository / 'restored/i20_book')


def test_restore_verifies_destination_bytes_before_publication(book, tmp_path, monkeypatch):
    output = tmp_path / 'backup'
    backup.create(book, output)
    original = backup.copy_checked
    def corrupt_destination(source, destination, expected=None):
        result = original(source, destination, expected)
        destination.write_text('simulated bad destination bytes')
        return result
    monkeypatch.setattr(backup, 'copy_checked', corrupt_destination)
    restored = tmp_path / 'restored/i20_book'
    with pytest.raises(backup.BackupError, match='checksum'):
        backup.restore(output, restored)
    assert not restored.exists()
    assert not list(restored.parent.glob('.i20_book.partial-*'))
