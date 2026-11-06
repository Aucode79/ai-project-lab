"""Foreign operations and execution evidence. Control flow comes from generated code."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
import uuid
from types import GeneratorType

from module_compiler import TOOLS
from run_agent import credentials

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'sidecar'))
from mcp_sidecar.cli import rpc, file_action
from mcp_sidecar.fs_tools import ScopedFs


class Cancelled(BaseException):
    pass


class Runtime:
    def __init__(self, run_dir, workspace, callback=None, model_fn=None):
        self.run_dir = Path(run_dir)
        self.workspace = str(workspace)
        self.fs = ScopedFs(Path(self.workspace))
        self.callback = callback
        self.model_fn = model_fn
        self.cancel = threading.Event()
        self.stack = []
        self.events = []
        self.seq = 0
        self.model_count = 0
        self.client = None
        self.manifest = {'runId': self.run_dir.name, 'workspace': self.workspace, 'tools': [],
                         'capability': uuid.uuid4().hex}

    def emit(self, kind, **data):
        self.check_cancel()
        event = dict(seq=len(self.events), time=time.time(), kind=kind, runId=self.run_dir.name, **data)
        event = json.loads(json.dumps(event, ensure_ascii=False, default=str))
        self.events.append(event)
        with (self.run_dir / 'execution.jsonl').open('a', encoding='utf-8') as f:
            f.write(json.dumps(event, ensure_ascii=False) + '\n')
        if self.callback:
            self.callback(event)

    def check_cancel(self):
        if self.cancel.is_set():
            raise Cancelled('用户已停止运行')

    def enter(self, module, arguments):
        self.seq += 1
        cid = str(self.seq)
        self.emit('enter', callId=cid, parentCallId=self.stack[-1] if self.stack else None,
                  moduleId=module, inputs=arguments)
        self.stack.append(cid)
        return cid

    def leave(self, cid):
        # Cleanup must also work while cancellation is unwinding the Python stack.
        if not self.cancel.is_set():
            self.emit('leave', callId=cid)
        if self.stack and self.stack[-1] == cid:
            self.stack.pop()

    def node(self, cid, module, node, inputs):
        self.emit('node', callId=cid, moduleId=module, nodeId=node, inputs=inputs)

    def value(self, cid, module, node, value):
        if isinstance(value, GeneratorType):
            value = {'kind': 'generator', 'state': 'lazy'}
        self.emit('value', callId=cid, moduleId=module, nodeId=node, value=value)

    def lazy_generator(self, module, node, call_id, items, item_node, filters, element_node, element):
        iterator = iter(items)
        self.node(call_id, module, node, {'phase': 'create'})

        def iterate():
            index = 0
            while True:
                self.check_cancel()
                try:
                    item = next(iterator)
                except StopIteration:
                    return
                self.node(call_id, module, node, {'index': index})
                if item_node:
                    self.value(call_id, module, item_node, item)
                accepted = True
                for filter_id, predicate in filters:
                    passed = predicate(item)
                    self.value(call_id, module, filter_id, passed)
                    if not passed:
                        accepted = False
                        break
                if accepted:
                    value = element(item)
                    if element_node:
                        self.value(call_id, module, element_node, value)
                    self.value(call_id, module, node, value)
                    yield value
                index += 1

        return iterate()

    def file_io(self, operation, args, encoding='utf-8', native_open=False):
        if operation not in ('read', 'write'):
            raise ValueError('unsupported file operation: ' + str(operation))
        tool = 'fs.' + operation
        self.emit('tool.start', tool=tool, args=args)
        if operation == 'read' and native_open:
            path = args['path']
            content = self.fs.resolve_safe(path).read_text(encoding=encoding)
            result = {'ok': True, 'path': path, 'content': content,
                      'bytes': len(content.encode('utf-8')), 'touched_paths': []}
        else:
            result = file_action(self.fs, operation, args)
        self.emit('tool.result', tool=tool, args=args, result=result)
        return result['content'] if operation == 'read' else None

    @staticmethod
    def message(role, value):
        return {'role': role, 'content': value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)}

    def model(self, messages, tools):
        self.check_cancel()
        if len(tools) != len(set(tools)) or any(t not in TOOLS for t in tools):
            raise ValueError('无效工具集合')
        self.manifest['tools'] = list(tools)
        (self.run_dir / 'capabilities.json').write_text(json.dumps(self.manifest, ensure_ascii=False), encoding='utf-8')
        schema = {t: TOOLS[t] for t in tools}
        system = ('你是沙盒中的智能体。每次只返回 JSON {"tool":"工具名","args":{...}}。'
                  '可用工具及参数：' + json.dumps(schema, ensure_ascii=False) +
                  '。finish {"text":"结果"} 表示完成或说明不能完成。'
                  'world.move 只移动运输车一段相邻道路；pickup 装载当前位置货物；drop 卸载。'
                  'fs.list path 可用 . 。文件路径均相对工作目录。工具失败会返回错误对象。'
                  '根据实际工具返回完成用户任务，不能把尚未执行的操作说成已完成。')
        request_messages = [{'role': 'system', 'content': system}] + copy.deepcopy(messages)
        self.model_count += 1
        index = self.model_count
        if self.model_fn:
            result = self.model_fn(request_messages, tools)
            return result
        if self.client is None:
            from openai import OpenAI
            config = credentials()
            self.model_name = config['SMOL_MODEL'] or 'deepseek-flash'
            self.client = OpenAI(api_key=config['SMOL_API_KEY'], base_url=config['SMOL_BASE_URL'],
                                 timeout=90, max_retries=0)
        request = dict(model=self.model_name, messages=request_messages, temperature=0.1,
                       max_tokens=4096, response_format={'type': 'json_object'})
        (self.run_dir / ('request-%03d.json' % index)).write_text(json.dumps(request, ensure_ascii=False, indent=2), encoding='utf-8')
        self.emit('model.start', tools=tools, requestFile='request-%03d.json' % index)
        response = self.client.chat.completions.create(**request)
        (self.run_dir / ('response-%03d-full.json' % index)).write_text(response.model_dump_json(), encoding='utf-8')
        self.check_cancel()
        raw = response.choices[0].message.content
        if not isinstance(raw, str) or not raw.strip():
            raise RuntimeError('模型没有返回可执行内容；finish_reason=' + str(response.choices[0].finish_reason))
        (self.run_dir / ('response-%03d.json' % index)).write_text(raw, encoding='utf-8')
        result = json.loads(raw)
        self.emit('model.result', response=result, tokens=response.usage.total_tokens if response.usage else 0)
        return result

    def dispatch(self, action, tools):
        tool = action.get('tool')
        if tool not in tools or tool not in self.manifest['tools']:
            return {'ok': False, 'error': {'code': 'tool_not_connected', 'message': str(tool)}}
        args = action.get('args', {})
        expected = TOOLS[tool]
        if not isinstance(args, dict) or set(args) != set(expected) or any(not isinstance(args[k], str) for k in expected):
            return {'ok': False, 'error': {'code': 'bad_args', 'message': '参数必须符合工具接口'}}
        request = {'args': args, 'manifest': str(self.run_dir / 'capabilities.json'),
                   'capability': self.manifest['capability']}
        self.emit('tool.start', tool=tool, args=args)
        domain, command = tool.split('.')
        proc = subprocess.run([sys.executable, '-m', 'mcp_sidecar.cli', domain, command],
            input=json.dumps(request, ensure_ascii=False), text=True, encoding='utf-8', capture_output=True,
            cwd=ROOT / 'sidecar', timeout=25, creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
        result = json.loads(proc.stdout)
        self.emit('tool.result', tool=tool, args=args, result=result, exitCode=proc.returncode)
        return result
