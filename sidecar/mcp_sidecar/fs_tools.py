"""fs.read / fs.write / fs.list：作用域目录内的文件世界（docs/10-契约/mini-codex.md §2.3）。

语义（spec §7.2 工具与载体）：
  * 读走扫描器 —— **读不留物**：touched_paths 恒为空
  * 写走机械臂 —— **写留物**：touched_paths 带本次落笔的相对路径
沙箱：所有路径先 resolve 再校验必须落在作用域根内，越界一律拒绝
（绝对路径、.. 逃逸、符号链接逃逸都算越界）。
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

WORKSPACE_ENV = "SIDECAR_WORKSPACE"


class FsError(Exception):
    """带结构化 code 的文件工具错误。"""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def default_workspace() -> Path:
    """默认作用域：sidecar/workspace（可用 SIDECAR_WORKSPACE 覆盖）。"""
    raw = os.environ.get(WORKSPACE_ENV, "").strip()
    if raw:
        return Path(raw).expanduser().resolve()
    return (Path(__file__).resolve().parent.parent / "workspace").resolve()


class ScopedFs:
    """一个作用域根 + 三个操作。所有返回值都是可 JSON 化的 dict。"""

    def __init__(self, root: Path | None = None) -> None:
        self.root = (root or default_workspace()).resolve()
        self.root.mkdir(parents=True, exist_ok=True)

    # ---------- 路径沙箱 ----------

    def _resolve(self, rel: str) -> Path:
        if not isinstance(rel, str) or not rel.strip():
            raise FsError("bad_path", "path 必须是非空字符串")
        candidate = Path(rel)
        # 绝对路径 / 盘符 / 根锚定（含 UNC）一律拒绝：作用域内只有相对路径
        if candidate.is_absolute() or candidate.root or candidate.drive:
            raise FsError("path_out_of_scope", f"只接受作用域内的相对路径，得到：{rel}")
        # resolve 跟随符号链接；随后必须仍落在根内
        full = (self.root / candidate).resolve()
        if full != self.root and self.root not in full.parents:
            raise FsError("path_out_of_scope", f"路径越出作用域 {self.root}：{rel}")
        return full

    def resolve_safe(self, rel: str) -> Path:
        """公开的沙箱校验（run_tools 等同包消费者用）。"""
        return self._resolve(rel)

    # ---------- 工具实现 ----------

    def read(self, path: str) -> dict[str, Any]:
        full = self._resolve(path)
        if not full.is_file():
            raise FsError("not_found", f"文件不存在：{path}")
        try:
            content = full.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            raise FsError("read_error", f"读 {path} 失败：{exc}") from exc
        return {
            "ok": True,
            "path": path,
            "content": content,
            "bytes": len(content.encode("utf-8")),
            # 读不留物（扫描器痕迹在世界里，不落文件系统）
            "touched_paths": [],
        }

    def write(self, path: str, content: str) -> dict[str, Any]:
        if not isinstance(content, str):
            raise FsError("bad_args", "content 必须是字符串")
        full = self._resolve(path)
        if full == self.root:
            raise FsError("bad_path", "不能把作用域根当文件写")
        try:
            full.parent.mkdir(parents=True, exist_ok=True)
            full.write_text(content, encoding="utf-8")
        except OSError as exc:
            raise FsError("write_error", f"写 {path} 失败：{exc}") from exc
        return {
            "ok": True,
            "path": path,
            "bytes_written": len(content.encode("utf-8")),
            # 写留物（机械臂落点）
            "touched_paths": [path],
        }

    def list(self, path: str = ".") -> dict[str, Any]:
        full = self._resolve(path)
        if not full.exists():
            raise FsError("not_found", f"路径不存在：{path}")
        if full.is_file():
            return {
                "ok": True,
                "path": path,
                "entries": [{
                    "name": full.name,
                    "type": "file",
                    "bytes": full.stat().st_size,
                }],
                "touched_paths": [],
            }
        entries = []
        for child in sorted(full.iterdir(), key=lambda p: p.name):
            if child.is_dir():
                entries.append({"name": child.name, "type": "dir"})
            else:
                entries.append({
                    "name": child.name,
                    "type": "file",
                    "bytes": child.stat().st_size,
                })
        return {
            "ok": True,
            "path": path,
            "entries": entries,
            "touched_paths": [],
        }
