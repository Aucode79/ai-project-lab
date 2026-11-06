"""fs 作用域沙箱：越界拒绝 + 读不留物 / 写留物语义。"""

from __future__ import annotations

import os

import pytest

from mcp_sidecar.fs_tools import FsError, ScopedFs


@pytest.fixture()
def fs(tmp_path) -> ScopedFs:
    return ScopedFs(tmp_path / "ws")


def test_write_read_roundtrip(fs: ScopedFs) -> None:
    w = fs.write("notes/a.txt", "hello 世界")
    assert w["ok"] and w["bytes_written"] == len("hello 世界".encode())
    assert w["touched_paths"] == ["notes/a.txt"]  # 写留物
    r = fs.read("notes/a.txt")
    assert r["ok"] and r["content"] == "hello 世界"
    assert r["touched_paths"] == []  # 读不留物
    assert (fs.root / "notes" / "a.txt").is_file()


def test_read_missing_is_structured_error(fs: ScopedFs) -> None:
    with pytest.raises(FsError) as ei:
        fs.read("nope.txt")
    assert ei.value.code == "not_found"


def test_absolute_paths_rejected(fs: ScopedFs) -> None:
    for bad in ("/etc/passwd", os.path.join("C:", "x", "y") if os.name == "nt" else "/abs"):
        with pytest.raises(FsError) as ei:
            fs.read(bad)
        assert ei.value.code == "path_out_of_scope"


def test_dotdot_escape_rejected(fs: ScopedFs) -> None:
    fs.write("inside.txt", "x")
    with pytest.raises(FsError) as ei:
        fs.read("../outside.txt")
    assert ei.value.code == "path_out_of_scope"
    with pytest.raises(FsError):
        fs.write("a/../../evil.txt", "x")


def test_symlink_escape_rejected(fs: ScopedFs) -> None:
    if os.name != "posix":
        pytest.skip("符号链接逃逸只在 posix 下可测")
    outside = fs.root.parent / "outside.txt"
    outside.write_text("secret", encoding="utf-8")
    link = fs.root / "link.txt"
    link.symlink_to(outside)
    with pytest.raises(FsError) as ei:
        fs.read("link.txt")
    assert ei.value.code == "path_out_of_scope"


def test_list_entries(fs: ScopedFs) -> None:
    fs.write("b.txt", "22")
    fs.write("a/c.txt", "1")
    out = fs.list(".")
    assert out["ok"] and out["touched_paths"] == []
    names = {e["name"] for e in out["entries"]}
    assert {"a", "b.txt"} <= names
    sub = fs.list("a")
    assert sub["entries"] == [{"name": "c.txt", "type": "file", "bytes": 1}]


def test_workspace_env_override(tmp_path, monkeypatch) -> None:
    ws = tmp_path / "envws"
    monkeypatch.setenv("SIDECAR_WORKSPACE", str(ws))
    s = ScopedFs()
    assert s.root == ws.resolve()
    s.write("x.txt", "1")
    assert (ws / "x.txt").is_file()


def test_bad_types_rejected(fs: ScopedFs) -> None:
    with pytest.raises(FsError):
        fs.read("")
    with pytest.raises(FsError):
        fs.write("x.txt", content=123)  # type: ignore[arg-type]
