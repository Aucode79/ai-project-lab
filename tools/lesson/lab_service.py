"""Local editor API and generated-program launcher for Agent Lab."""
import copy
import hashlib
import json
from pathlib import Path
import shutil
import sys
import threading
import time
import traceback
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from types import GeneratorType

from lab_preset import preset
from module_compiler import compile_program, semantic, PORTS, TOOLS, ports
from import_python import import_source
from lab_runtime import ROOT, Runtime, Cancelled
from mcp_sidecar.cli import rpc, documents, file_action
from mcp_sidecar.fs_tools import ScopedFs

STATE = ROOT / 'game' / 'agent-lab'
WORKSPACE = STATE / 'workspace'
RUNS = ROOT / 'game' / 'runs' / 'agent-lab'
PROGRAM = STATE / 'program.json'


class Lab:
    def __init__(self):
        STATE.mkdir(parents=True, exist_ok=True)
        RUNS.mkdir(parents=True, exist_ok=True)
        self.fs = ScopedFs(WORKSPACE)
        first_start = not PROGRAM.exists()
        if first_start:
            PROGRAM.write_text(json.dumps(preset(), ensure_ascii=False, indent=2), encoding='utf-8')
        if first_start and not (WORKSPACE / '任务.md').exists():
            (WORKSPACE / '任务.md').write_text('把货物、蓝方块和黄方块全部运到 D。道路可能改变，请根据最新状态选择路线。\n'
                '完成后重新查询世界，在报告.md 写明最终位置、遇到的障碍以及完成情况。\n', encoding='utf-8')
        self.program = json.loads(PROGRAM.read_text(encoding='utf-8'))
        self.lock = threading.Lock()
        self.runtime = None
        self.status = 'idle'
        self.result = None
        self.run_dir = None
        self.revision = 0
        self.inventory = []
        self.sync_error = ''
        threading.Thread(target=self.sync_loop, daemon=True).start()

    def sync_loop(self):
        last = None
        while True:
            try:
                inv = documents(self.fs)
                if inv != last:
                    response = rpc('documents.sync', {'documents': inv})
                    if response.get('ok'):
                        last = inv
                self.inventory = inv
                self.sync_error = ''
            except Exception as exc:
                self.sync_error = str(exc)
                last = None
            time.sleep(0.7)

    def event(self, event):
        # Persistent execution.jsonl is authoritative for node events.
        # The world receives IDs and node labels for live highlighting, not a fake timeline.
        try:
            rpc('execution', {'event': {k: event[k] for k in ('kind', 'moduleId', 'nodeId', 'callId', 'tool') if k in event}})
        except OSError:
            pass

    def start(self, task):
        with self.lock:
            if self.status == 'running':
                raise ValueError('已有运行正在执行')
            program = copy.deepcopy(self.program)
            compiled = compile_program(program)
            if not compiled['ok']:
                return compiled
            inputs = program['modules'][program['entry']].get('inputs', [])
            if len(inputs) == 1:
                arguments = {inputs[0]: task}
            elif not inputs:
                arguments = {}
            elif isinstance(task, dict) and all(name in task for name in inputs):
                arguments = {name: task[name] for name in inputs}
            else:
                return {'ok': False, 'errors': [{'message': '任务值缺少程序入口参数：' + ', '.join(inputs)}]}
            self.run_dir = RUNS / ('r-' + uuid.uuid4().hex)
            self.run_dir.mkdir()
            for name, value in [('program.json', program), ('compile.json', compiled)]:
                (self.run_dir / name).write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding='utf-8')
            (self.run_dir / 'program.py').write_text(compiled['python'], encoding='utf-8')
            self.runtime = Runtime(self.run_dir, WORKSPACE, self.event)
            self.status, self.result = 'running', None
            self.run_revision = self.revision
            try:
                rpc('lab.begin', {'task': task, 'runId': self.run_dir.name, 'hash': compiled['ir_hash']})
            except Exception:
                self.status = 'failed'
                raise
            threading.Thread(target=self.execute, args=(compiled, arguments, self.runtime), daemon=True).start()
            return {'ok': True, 'runId': self.run_dir.name}

    def execute(self, compiled, arguments, runtime):
        try:
            scope = {}
            exec(compile(compiled['python'], str(self.run_dir / 'program.py'), 'exec'), scope)
            result = scope['run'](runtime, **arguments)
            if isinstance(result, GeneratorType):
                values = []
                while True:
                    runtime.check_cancel()
                    try:
                        values.append(next(result))
                    except StopIteration:
                        break
                result = values
            status = 'complete'
        except Cancelled as exc:
            status, result = 'cancelled', str(exc)
        except Exception as exc:
            status, result = 'failed', {'error': str(exc), 'traceback': traceback.format_exc()}
        self.result = result
        (runtime.run_dir / 'result.json').write_text(json.dumps({'status': status, 'result': result,
            'modelCalls': runtime.model_count, 'events': len(runtime.events)}, ensure_ascii=False, indent=2), encoding='utf-8')
        try:
            trace = rpc('lab.end', {'status': status, 'result': result})
            (runtime.run_dir / 'world.json').write_text(json.dumps(trace, ensure_ascii=False, indent=2), encoding='utf-8')
        except Exception as exc:
            (runtime.run_dir / 'world-error.txt').write_text(str(exc), encoding='utf-8')
        self.status = status

    def get(self, path):
        if path == '/program':
            p = copy.deepcopy(self.program)
            for module in p.get('modules', {}).values():
                for node in module.get('nodes', []):
                    if node.get('op') != 'const':
                        continue
                    value = node.get('params', {}).get('value')
                    if type(value) in (int, float):
                        node.setdefault('params', {})['literalType'] = 'int' if type(value) is int else 'float'
            return {'ok': True, 'program': p, 'catalog': list(PORTS), 'tools': sorted(TOOLS), 'revision': self.revision}
        if path.startswith('/state'):
            cursor = int(path.split('after=')[-1]) if 'after=' in path else 0
            events = self.runtime.events[cursor:cursor + 100] if self.runtime else []
            return {'ok': True, 'status': self.status, 'result': self.result, 'documents': self.inventory,
                    'events': events, 'revision': self.revision, 'runRevision': getattr(self, 'run_revision', -1),
                    'syncError': self.sync_error, 'totalEvents': len(self.runtime.events) if self.runtime else 0,
                    'runId': self.run_dir.name if self.run_dir else ''}
        raise ValueError('Unknown endpoint')

    def post(self, path, data):
        if path == '/compile':
            return compile_program(data.get('program', self.program))
        if path == '/import':
            source = data.get('source')
            filename = data.get('filename', '')
            if not isinstance(source, str) or not isinstance(filename, str) or not filename.lower().endswith('.py'):
                raise ValueError('请选择 UTF-8 编码的 .py 文件')
            if len(source.encode('utf-8')) > 1024 * 1024:
                raise ValueError('Python 文件不能超过 1 MiB')
            program = import_source(source.lstrip('\ufeff'))
            check = compile_program(program)
            if not check['ok']:
                return {'ok': False, 'errors': check['errors']}
            with self.lock:
                if data.get('revision') != self.revision:
                    raise ValueError('程序已改变，请重新载入后导入')
                suffix = uuid.uuid4().hex[:8]
                backup = PROGRAM.with_name('program.before-import-' + suffix + '.json')
                if PROGRAM.exists():
                    shutil.copy2(PROGRAM, backup)
                temporary = PROGRAM.with_name('program.import-' + suffix + '.tmp')
                try:
                    temporary.write_text(json.dumps(program, ensure_ascii=False, indent=2), encoding='utf-8')
                    temporary.replace(PROGRAM)
                finally:
                    temporary.unlink(missing_ok=True)
                self.program = copy.deepcopy(program)
                self.revision += 1
                return {'ok': True, 'entry': program['entry'], 'revision': self.revision,
                        'backup': backup.name if backup.exists() else ''}
        if path == '/program':
            if data.get('revision', self.revision) != self.revision:
                raise ValueError('程序已改变，请重新加载')
            program = data['program']
            with self.lock:
                old_modules = self.program.get('modules', {})
                for mid, module in program.get('modules', {}).items():
                    old_nodes = {node.get('id'): node for node in old_modules.get(mid, {}).get('nodes', [])}
                    for node in module.get('nodes', []):
                        old_node = old_nodes.get(node.get('id'), {})
                        if old_node.get('op') != node.get('op'):
                            continue
                        old_params = old_node.get('params', {})
                        params = node.get('params', {})
                        literal_type = params.get('literalType', '')
                        explicit_value_type = node.get('op') == 'const' and literal_type in ('int', 'float')
                        if explicit_value_type and type(params.get('value')) in (int, float):
                            value = params['value']
                            params['value'] = int(value) if literal_type == 'int' else float(value)
                        for key, value in list(params.items()):
                            if key == 'value' and explicit_value_type:
                                continue
                            old_value = old_params.get(key)
                            if type(old_value) is int and type(value) is float \
                                    and value.is_integer() and int(value) == old_value:
                                params[key] = old_value
                # Drafts can be saved with validation errors, but cannot run.
                check = compile_program(program)
                if semantic(program) != semantic(self.program):
                    for module in program.get('modules', {}).values():
                        for node in module.get('nodes', []):
                            if 'sourceText' in node:
                                node['label'] = node.get('params', {}).get('target', node['op'])
                            node.pop('sourceText', None)
                            node.pop('sourceSpan', None)
                self.program = copy.deepcopy(program)
                PROGRAM.write_text(json.dumps(program, ensure_ascii=False, indent=2), encoding='utf-8')
                self.revision += 1
            return {'ok': True, 'revision': self.revision, 'validation': check,
                    'program': copy.deepcopy(program)}
        if path == '/run':
            return self.start(data['task'])
        if path == '/stop':
            if self.runtime:
                self.runtime.cancel.set()
            return {'ok': True}
        if path == '/document':
            result = file_action(self.fs, data['operation'], data.get('args', {}))
            rpc('documents.sync', {'documents': documents(self.fs)})
            return result
        raise ValueError('Unknown endpoint')


def main():
    lab = Lab()
    class Handler(BaseHTTPRequestHandler):
        def respond(self, operation):
            try:
                response = operation()
                code = 200
            except Exception as exc:
                response, code = {'ok': False, 'error': str(exc)}, 400
            content = json.dumps(response, ensure_ascii=False).encode('utf-8')
            self.send_response(code)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Content-Length', str(len(content)))
            self.end_headers()
            self.wfile.write(content)
        def do_GET(self):
            self.respond(lambda: lab.get(self.path))
        def do_POST(self):
            self.respond(lambda: lab.post(self.path, json.loads(self.rfile.read(int(self.headers['Content-Length'])))))
        def log_message(self, fmt, *args):
            pass
    print('AGENT LAB http://127.0.0.1:7332', flush=True)
    ThreadingHTTPServer(('127.0.0.1', 7332), Handler).serve_forever()


if __name__ == '__main__':
    main()
