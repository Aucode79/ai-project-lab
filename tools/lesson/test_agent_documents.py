import tempfile
from pathlib import Path
import threading
import unittest
from unittest.mock import patch

import lab_service
from mcp_sidecar.cli import file_action, documents
from mcp_sidecar.fs_tools import ScopedFs, FsError


class DocumentBehavior(unittest.TestCase):
    def test_deleted_task_is_not_recreated_on_restart(self):
        with tempfile.TemporaryDirectory() as td:
            state = Path(td)
            with patch.multiple(lab_service, STATE=state, WORKSPACE=state / 'workspace', RUNS=state / 'runs', PROGRAM=state / 'program.json'), patch('threading.Thread.start'):
                lab_service.Lab()
                task = state / 'workspace' / '任务.md'
                self.assertTrue(task.exists())
                task.unlink()
                lab_service.Lab()
                self.assertFalse(task.exists(), '用户删除的文档不能在服务重启后自动复活')

    def test_lifecycle_and_conflict(self):
        with tempfile.TemporaryDirectory() as td:
            fs = ScopedFs(Path(td))
            file_action(fs, 'write', {'path': '子目录/任务.md', 'content': 'first', 'version': None})
            old = file_action(fs, 'read', {'path': '子目录/任务.md'})
            (Path(td) / '子目录/任务.md').write_text('external', encoding='utf-8')
            conflict = file_action(fs, 'write', {'path': '子目录/任务.md', 'content': 'stale', 'version': old['version']})
            self.assertFalse(conflict['ok'])
            self.assertEqual(fs.read('子目录/任务.md')['content'], 'external')
            file_action(fs, 'rename', {'path': '子目录/任务.md', 'target': '报告.md'})
            self.assertEqual([x['path'] for x in documents(fs)], ['报告.md'])
            file_action(fs, 'delete', {'path': '报告.md'})
            self.assertEqual(documents(fs), [])

    def test_new_document_does_not_overwrite_existing(self):
        with tempfile.TemporaryDirectory() as td:
            fs = ScopedFs(Path(td))
            fs.write('a.md', 'existing')
            self.assertFalse(file_action(fs, 'write', {'path': 'a.md', 'content': 'lost', 'version': None})['ok'])
            with self.assertRaises(FsError):
                fs.read('../outside')


if __name__ == '__main__':
    unittest.main()
