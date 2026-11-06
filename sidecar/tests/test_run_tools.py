"""run.python / run.tests：结构化返回 + 超时杀进程。"""

from __future__ import annotations

from pathlib import Path

import pytest

from mcp_sidecar.fs_tools import ScopedFs
from mcp_sidecar.run_tools import Runner


@pytest.fixture()
def runner(tmp_path) -> Runner:
    fs = ScopedFs(tmp_path / "ws")
    return Runner(fs)


def test_run_python_success(runner: Runner) -> None:
    ret = runner.run_python("print('hi', 1 + 1)")
    assert ret["ok"] and ret["exit_code"] == 0
    assert "hi 2" in ret["stdout"]
    assert ret["timed_out"] is False
    assert ret["touched_paths"] == []  # 执行器不留物
    # 临时文件即写即删
    assert not list((runner.fs.root / ".run").glob("*.py"))


def test_run_python_failure_exit_code(runner: Runner) -> None:
    ret = runner.run_python("import sys; sys.stderr.write('boom\\n'); sys.exit(3)")
    assert not ret["ok"] and ret["exit_code"] == 3
    assert "boom" in ret["stderr"]


def test_run_python_timeout_kills(runner: Runner) -> None:
    ret = runner.run_python("import time; time.sleep(30)", timeout=1.0)
    assert not ret["ok"]
    assert ret["timed_out"] is True
    assert ret["exit_code"] is None
    assert ret["timeout_s"] == 1.0
    # 杀得干净：总耗时贴着超时上限（30 秒的活绝不能跑完）
    assert ret["duration_ms"] < 10_000


def test_run_python_bad_args(runner: Runner) -> None:
    from mcp_sidecar.fs_tools import FsError
    with pytest.raises(FsError):
        runner.run_python("   ")
    with pytest.raises(FsError):
        runner.run_python("print(1)", timeout=0)


def test_run_tests_exit_codes(runner: Runner) -> None:
    ws: Path = runner.fs.root
    (ws / "test_ok.py").write_text(
        "def test_ok():\n    assert 1 + 1 == 2\n", encoding="utf-8")
    good = runner.run_tests("test_ok.py", timeout=30.0)
    assert good["ok"] and good["exit_code"] == 0
    assert good["exit_code_meaning"] == "all_tests_passed"
    assert "1 passed" in good["summary"]

    (ws / "test_bad.py").write_text(
        "def test_bad():\n    assert False, 'nope'\n", encoding="utf-8")
    bad = runner.run_tests("test_bad.py", timeout=30.0)
    assert not bad["ok"] and bad["exit_code"] == 1
    assert bad["exit_code_meaning"] == "tests_failed"
    assert bad["touched_paths"] == []


def test_run_tests_no_tests(runner: Runner) -> None:
    (runner.fs.root / "empty_dir").mkdir()
    ret = runner.run_tests("empty_dir", timeout=30.0)
    # pytest 对存在但没收集到用例的目录退出码 5（no tests collected）
    assert ret["exit_code"] == 5
    assert ret["exit_code_meaning"] == "no_tests_collected"


def test_run_tests_scope_checked(runner: Runner) -> None:
    from mcp_sidecar.fs_tools import FsError
    with pytest.raises(FsError):
        runner.run_tests("../outside", timeout=5.0)
