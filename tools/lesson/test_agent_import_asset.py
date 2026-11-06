import http.server
import json
import os
from pathlib import Path
import subprocess
import threading
import tempfile
import time
import urllib.request
import unittest
from unittest.mock import patch

import lab_service


class ImportedPythonAssetAcceptance(unittest.TestCase):
    def test_godot_import_edit_and_real_python_execution(self):
        repo = Path(__file__).resolve().parents[2]
        sample_path = repo / 'game/lesson_samples/editable_score_map.py'
        source = sample_path.read_text(encoding='utf-8')
        with tempfile.TemporaryDirectory() as td:
            temp = Path(td)

            class IsolatedServer:
                server = None
                worker = None
                port = 0

                def __init__(self, _address, handler):
                    self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
                    IsolatedServer.server = self.server
                    IsolatedServer.port = self.server.server_address[1]

                def serve_forever(self):
                    self.worker = threading.Thread(target=self.server.serve_forever, daemon=True)
                    self.worker.start()
                    IsolatedServer.worker = self.worker

            real_start = threading.Thread.start

            def start_without_sync_loop(thread, *args, **kwargs):
                if getattr(getattr(thread, '_target', None), '__name__', '') != 'sync_loop':
                    return real_start(thread, *args, **kwargs)

            with patch.multiple(lab_service, STATE=temp / 'state', WORKSPACE=temp / 'workspace',
                                RUNS=temp / 'runs', PROGRAM=temp / 'state' / 'program.json'), \
                    patch.object(lab_service, 'ThreadingHTTPServer', IsolatedServer), \
                    patch.object(threading.Thread, 'start', start_without_sync_loop), \
                    patch.object(lab_service, 'rpc', return_value={'ok': True}):
                with patch('builtins.print'):
                    lab_service.main()
                self.addCleanup(IsolatedServer.worker.join, timeout=1)
                self.addCleanup(IsolatedServer.server.server_close)
                self.addCleanup(IsolatedServer.server.shutdown)
                base = 'http://127.0.0.1:%d' % IsolatedServer.port
                env = os.environ.copy()
                env['AGENT_LAB_API_URL'] = base
                env['AGENT_LAB_ACCEPTANCE_FILE'] = str(sample_path)
                env['AGENT_LAB_NO_WORLD_SERVER'] = '1'
                env.pop('AGENT_LAB_SAMPLE', None)
                godot = repo / 'tools/godot/Godot_v4.7.2-stable_win64_console.exe'
                harness = 'res://tests/agent_lab/import_asset_acceptance_harness.gd'
                try:
                    result = subprocess.run([str(godot), '--headless', '--path', str(repo / 'game'),
                        '-s', harness], cwd=repo, env=env, capture_output=True, text=True, timeout=60)
                except subprocess.TimeoutExpired as exc:
                    stdout = exc.stdout.decode('utf-8', 'replace') if isinstance(exc.stdout, bytes) else (exc.stdout or '')
                    stderr = exc.stderr.decode('utf-8', 'replace') if isinstance(exc.stderr, bytes) else (exc.stderr or '')
                    self.fail('Godot acceptance timed out:\n' + stdout + stderr)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

                def get(path):
                    with urllib.request.urlopen(base + path, timeout=3) as response:
                        return json.load(response)

                saved = get('/program')
                self.assertTrue(saved['ok'])
                program = saved['program']
                edited_values = [node['params']['value'] for module in program['modules'].values()
                                 for node in module['nodes']
                                 if node['op'] == 'const' and node.get('params', {}).get('value') == 3]
                self.assertTrue(edited_values, 'the F2 edit must persist in the actual program graph')
                self.assertTrue(any(node['params'].get('literalType') == 'int'
                                    for module in program['modules'].values() for node in module['nodes']
                                    if node['op'] == 'const' and node.get('params', {}).get('value') == 3),
                                'F2 must retain the selected integer type')
                untouched_integer_values = [node['params']['value'] for module in program['modules'].values()
                                            for node in module['nodes'] if node['op'] == 'const'
                                            and node.get('params', {}).get('value') == 0]
                self.assertTrue(any(type(value) is int for value in untouched_integer_values),
                                'saving F2 must preserve integer types of untouched constants')
                state = get('/state?after=0')
                self.assertEqual(state['status'], 'complete')
                native = {}
                exec(source.replace('value * 2', 'value * 3'), native)
                expected = native['main']([1, -2, 3])
                self.assertEqual(state['result'], expected)
                self.assertEqual(state['result'], {'value-01': 3, 'value-03': 9})
                for key in expected:
                    self.assertIs(type(state['result'][key]), type(expected[key]))
                frozen = json.loads((temp / 'runs' / state['runId'] / 'program.json')
                                    .read_text(encoding='utf-8'))
                self.assertTrue(any(node['op'] == 'const' and node.get('params', {}).get('value') == 3
                                    for module in frozen['modules'].values() for node in module['nodes']))
                dict_ids = {node['id'] for module in frozen['modules'].values() for node in module['nodes']
                            if node['op'] == 'dictcomp'}
                self.assertEqual([event['inputs']['index'] for event in state['events']
                                  if event.get('nodeId') in dict_ids and event['kind'] == 'node'
                                  and 'index' in event.get('inputs', {})], [0, 1, 2])


if __name__ == '__main__':
    unittest.main()
