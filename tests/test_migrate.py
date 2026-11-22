"""Migration checks using invented records only; no private archive is needed."""
import importlib.util
import sys
from pathlib import Path
import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'tools'))
import migrate

spec = importlib.util.spec_from_file_location('synthetic_source', ROOT / 'ios/Tests/Fixtures/make_fixture_book.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


@pytest.fixture
def archive(tmp_path):
    source = tmp_path / 'source'
    fixture.build_src(source)
    return source, tmp_path / 'i20_book'


def run(archive, **options):
    source, dest = archive
    return migrate.migrate(dest, src_raw=source / 'raw', csv_path=source / 'fuel.csv',
                           service_log=source / 'service_log.json', out=lambda *_: None, **options)


def test_synthetic_migration_preserves_source_and_is_idempotent(archive):
    source, dest = archive
    before = migrate.tree_hash(source)
    run(archive)
    snapshot = migrate.tree_hash(dest)
    run(archive)
    assert migrate.tree_hash(dest) == snapshot
    assert migrate.tree_hash(source) == before
    assert len(list((dest / 'log/refuels').glob('*.json'))) == 3
    assert len(list((dest / 'log/services').glob('*.json'))) == 1
    for file in (source / 'raw').rglob('*.json'):
        assert migrate.sha256(file) == migrate.sha256(dest / 'raw' / file.relative_to(source / 'raw'))


def test_dry_run_writes_nothing(archive):
    run(archive, dry_run=True)
    assert not archive[1].exists()


def test_conflict_preflight_preserves_destination(archive):
    source, dest = archive
    name = next((source / 'raw/trips').rglob('*.json')).relative_to(source / 'raw')
    target = dest / 'raw' / name
    target.parent.mkdir(parents=True)
    target.write_text('different content')
    before = migrate.tree_hash(dest)
    with pytest.raises(migrate.MigrationError, match='different content'):
        run(archive)
    assert migrate.tree_hash(dest) == before


def test_symlink_escape_is_refused(archive, tmp_path):
    _, dest = archive
    outside = tmp_path / 'outside'
    outside.mkdir()
    dest.mkdir()
    (dest / 'raw').symlink_to(outside)
    with pytest.raises(migrate.MigrationError, match='outside'):
        run(archive)
    assert not list(outside.iterdir())
