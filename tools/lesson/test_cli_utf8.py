import json
import os
from pathlib import Path
import socketserver
import subprocess
import sys
import tempfile
import threading
import unittest


class CliUtf8(unittest.TestCase):
    def test_cli_rejects_disconnected_tool_before_side_effect(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            manifest = root / 'manifest.json'
            manifest.write_text(json.dumps({'tools': ['fs.read'], 'workspace': td, 'runId': 'test', 'capability': 'test'}), encoding='utf-8')
            for capability in ['test', 'wrong']:
                request = {'manifest': str(manifest), 'capability': capability, 'args': {'path': 'denied.txt', 'content': 'bad'}}
                result = subprocess.run([sys.executable, '-m', 'mcp_sidecar.cli', 'fs', 'write'], input=json.dumps(request).encode(),
                    capture_output=True, cwd=Path(__file__).resolve().parents[2] / 'sidecar', timeout=20)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(json.loads(result.stdout)['error']['code'], 'tool_not_connected')
                self.assertFalse((root / 'denied.txt').exists())

    def test_chinese_path_through_actual_stdin(self):
        class Bridge(socketserver.StreamRequestHandler):
            def handle(self):
                json.loads(self.rfile.readline())
                self.wfile.write(b'{"ok":true,"step":0}\n')
        with socketserver.TCPServer(('127.0.0.1', 0), Bridge) as server, tempfile.TemporaryDirectory() as td:
            threading.Thread(target=server.serve_forever, daemon=True).start()
            root = Path(td)
            (root / '任务.md').write_text('中文正文', encoding='utf-8')
            manifest = root / 'manifest.json'
            manifest.write_text(json.dumps({'tools': ['fs.read'], 'workspace': td, 'runId': 'test', 'capability': 'test'}), encoding='utf-8')
            request = {'manifest': str(manifest), 'capability': 'test', 'args': {'path': '任务.md'}}
            env = dict(os.environ, AGENT_LAB_PORT=str(server.server_address[1]), PYTHONIOENCODING='gbk')
            result = subprocess.run([sys.executable, '-m', 'mcp_sidecar.cli', 'fs', 'read'],
                input=json.dumps(request, ensure_ascii=False).encode('utf-8'), capture_output=True,
                cwd=Path(__file__).resolve().parents[2] / 'sidecar', env=env, timeout=20)
            server.shutdown()
            response = json.loads(result.stdout.decode('utf-8'))
            self.assertTrue(response['ok'], response)
            self.assertEqual(response['content'], '中文正文')


if __name__ == '__main__':
    unittest.main()
