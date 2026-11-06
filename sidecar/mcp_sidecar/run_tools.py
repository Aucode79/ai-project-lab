"""run.python / run.tests：子进程执行器（docs/10-契约/mini-codex.md 组件 #9 执行器）。

约定：
  * 子进程跑在作用域（workspace）里，代码临时文件放 workspace/.run/
  * 默认超时 10 秒，超时杀进程，结构化返回（stdout/stderr/exit_code 齐全）
  * run.tests 走 pytest，退出码按 pytest 语义解析
"""

from __future__ import annotations

import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any

from .fs_tools import FsError, ScopedFs

DEFAULT_TIMEOUT_S = 10.0
MAX_TIMEOUT_S = 60.0

# pytest 退出码语义（pytest 文档 §Exit codes）
PYTEST_EXIT_MEANING = {
    0: "all_tests_passed",
    1: "tests_failed",
    2: "interrupted_by_user",
    3: "internal_error",
    4: "usage_error",
    5: "no_tests_collected",
}


class Runner:
    def __init__(self, fs: ScopedFs, python_exe: str = sys.executable,
                 default_timeout: float = DEFAULT_TIMEOUT_S) -> None:
        self.fs = fs
        self.python_exe = python_exe
        self.default_timeout = default_timeout

    def _norm_timeout(self, timeout: float | None) -> float:
        t = self.default_timeout if timeout is None else float(timeout)
        if t <= 0:
            raise FsError("bad_args", f"timeout 必须为正数（秒），得到：{timeout}")
        return min(t, MAX_TIMEOUT_S)

    def _run(self, cmd: list[str], timeout: float) -> dict[str, Any]:
        start = time.perf_counter()
        try:
            proc = subprocess.run(
                cmd,
                cwd=self.fs.root,
                capture_output=True,
                text=True,
                timeout=timeout,
                encoding="utf-8",
                errors="replace",
            )
        except subprocess.TimeoutExpired as exc:
            # subprocess.run 超时后已 kill 子进程；把已产出的输出带回去
            out = exc.stdout.decode("utf-8", "replace") if isinstance(exc.stdout, bytes) else (exc.stdout or "")
            err = exc.stderr.decode("utf-8", "replace") if isinstance(exc.stderr, bytes) else (exc.stderr or "")
            return {
                "ok": False,
                "exit_code": None,
                "timed_out": True,
                "timeout_s": timeout,
                "stdout": out,
                "stderr": err,
                "duration_ms": int((time.perf_counter() - start) * 1000),
            }
        return {
            "ok": proc.returncode == 0,
            "exit_code": proc.returncode,
            "timed_out": False,
            "stdout": proc.stdout,
            "stderr": proc.stderr,
            "duration_ms": int((time.perf_counter() - start) * 1000),
        }

    # ---------- 工具实现 ----------

    def run_python(self, code: str, timeout: float | None = None) -> dict[str, Any]:
        if not isinstance(code, str) or not code.strip():
            raise FsError("bad_args", "code 必须是非空字符串")
        t = self._norm_timeout(timeout)
        run_dir = self.fs.root / ".run"
        run_dir.mkdir(parents=True, exist_ok=True)
        tmp = run_dir / f"py_{uuid.uuid4().hex[:12]}.py"
        tmp.write_text(code, encoding="utf-8")
        try:
            ret = self._run([self.python_exe, "-I", str(tmp)], t)
        finally:
            tmp.unlink(missing_ok=True)
        # 执行器不留物：临时文件即写即删；它产出的文件该由机械臂（fs.write）交付
        ret["touched_paths"] = []
        return ret

    def run_tests(self, path: str = ".", timeout: float | None = None) -> dict[str, Any]:
        if not isinstance(path, str) or not path.strip():
            raise FsError("bad_args", "path 必须是非空字符串")
        # 先做沙箱校验（越界路径直接拒绝，不进子进程）
        self.fs.resolve_safe(path)
        t = self._norm_timeout(timeout)
        ret = self._run([self.python_exe, "-m", "pytest", path, "-q", "--no-header"], t)
        ret["exit_code_meaning"] = PYTEST_EXIT_MEANING.get(ret["exit_code"], "unknown")
        ret["summary"] = _parse_pytest_summary(ret["stdout"])
        ret["touched_paths"] = []  # 执行器不留物（它写回的文件由机械臂交付）
        return ret


def _parse_pytest_summary(stdout: str) -> str:
    """从 -q 输出里抓最后一行摘要（"3 passed in 0.01s" 这类）。"""
    for line in reversed((stdout or "").strip().splitlines()):
        stripped = line.strip()
        if ("passed" in stripped or "failed" in stripped or "error" in stripped) \
                and "in " in stripped:
            return stripped
        if stripped.startswith(("=", "FAILED", "ERROR", "PASSED")):
            continue
    return ""
