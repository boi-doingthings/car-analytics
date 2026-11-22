import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import serve  # noqa: E402


def test_exit_code_mapping():
    assert serve.sync_error(0) is None
    assert serve.sync_error(3) == "Some files are still downloading from iCloud. Try again shortly."
    assert serve.sync_error(2) == "Can't read the i20_book folder in iCloud Drive."
    assert "exit 1" in serve.sync_error(1)


def test_run_sync_reports_error_without_touching_state(monkeypatch, tmp_path):
    monkeypatch.setattr(serve, "STATE", tmp_path / "last_sync.json")
    monkeypatch.setattr(serve, "run_cli", lambda: (3, 0))
    serve._status.update(running=True, step="x", error=None)
    serve.run_sync()
    assert serve._status["error"].startswith("Some files are still downloading")
    assert not serve._status["running"]
    assert not (tmp_path / "last_sync.json").exists()


def test_find_node_prefers_env_then_path_then_nvm(monkeypatch, tmp_path):
    monkeypatch.setenv("I20_NODE", "/x/node")
    assert serve.find_node() == "/x/node"
    monkeypatch.delenv("I20_NODE")
    monkeypatch.setattr(serve.shutil, "which", lambda n: "/usr/bin/node")
    assert serve.find_node() == "/usr/bin/node"
    monkeypatch.setattr(serve.shutil, "which", lambda n: None)
    for v in ("v9.0.0", "v22.1.0", "v10.0.0"):
        (tmp_path / ".nvm/versions/node" / v / "bin").mkdir(parents=True)
        (tmp_path / ".nvm/versions/node" / v / "bin/node").write_text("")
    monkeypatch.setenv("HOME", str(tmp_path))
    assert serve.find_node().endswith("v22.1.0/bin/node")


def test_missing_node_is_a_friendly_error(monkeypatch, tmp_path):
    monkeypatch.setattr(serve, "LOG", tmp_path / "log")
    monkeypatch.setattr(serve, "find_node", lambda: None)
    code, _ = serve.run_cli()
    assert serve.sync_error(code) == "Node.js not found \u2014 install it or set I20_NODE."
