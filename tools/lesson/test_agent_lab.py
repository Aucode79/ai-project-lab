"""Behavioral regression for visual-code semantics, not model success evidence."""
import copy
import http.server
import json
import os
from pathlib import Path
import threading
import tempfile
import time
import types
import unittest
import urllib.request
from types import SimpleNamespace
from unittest.mock import patch
import lab_service

from lab_preset import graph, node, preset
from module_compiler import compile_program
from lab_runtime import Runtime
from import_python import import_source
from mcp_sidecar.cli import file_action, documents
from mcp_sidecar.fs_tools import ScopedFs, FsError


def execute(program, arguments, model=None):
    compiled = compile_program(program)
    if not compiled['ok']:
        raise AssertionError(compiled['errors'])
    with tempfile.TemporaryDirectory() as td:
        rt = Runtime(td, td, model_fn=model)
        scope = {}
        exec(compiled['python'], scope)
        value = scope['run'](rt, **arguments)
        return value, rt.events


def recursive():
    n = node
    body = graph(['n'], 'branch', [n('n', 'input', params={'name': 'n'}),
        n('one', 'const', params={'value': 1}), n('minus', 'const', params={'value': -1}),
        n('zero', 'const', params={'value': 0}), n('test', 'lt'), n('decrement', 'add'),
        n('branch', 'branch'), n('recurse', 'call', module='sum'), n('sum', 'add'),
        n('base', 'return'), n('result', 'return')],
        [('n.value', 'test.a'), ('one.value', 'test.b'), ('test.value', 'branch.condition'),
         ('n.value', 'decrement.a'), ('minus.value', 'decrement.b'), ('decrement.value', 'recurse.n'),
         ('n.value', 'sum.a'), ('recurse.value', 'sum.b'), ('zero.value', 'base.value'), ('sum.value', 'result.value')],
        [('branch.then', 'base.exec'), ('branch.else', 'recurse.exec'), ('recurse.next', 'result.exec')])
    return {'formatVersion': 'module/1', 'entry': 'sum', 'modules': {'sum': body}}


class CompilerBehavior(unittest.TestCase):
    def test_graph_owns_agent_loop(self):
        seen = []
        def model(messages, tools):
            seen.append(copy.deepcopy(messages))
            return {'tool': 'finish', 'args': {'text': 'done'}}
        answer, events = execute(preset(), {'task': 'hello'}, model)
        self.assertEqual(answer['args']['text'], 'done')
        self.assertTrue(any(e.get('moduleId') == 'model_request' for e in events))
        self.assertEqual(seen[0][-1]['content'], 'hello')

    def test_recursive_calls_have_separate_frames(self):
        result, events = execute(recursive(), {'n': 8})
        self.assertEqual(result, 36)
        calls = [e for e in events if e['kind'] == 'enter']
        self.assertEqual(len(calls), 9)
        self.assertEqual(len({e['callId'] for e in calls}), 9)
        self.assertEqual(calls[1]['parentCallId'], calls[0]['callId'])

    def test_nested_references_beyond_four_layers(self):
        p = recursive()
        for i in range(7):
            target = 'sum' if i == 0 else 'wrap' + str(i - 1)
            p['modules']['wrap' + str(i)] = graph(['n'], 'call', [node('n', 'input', params={'name': 'n'}),
                node('call', 'call', module=target), node('return', 'return')],
                [('n.value', 'call.n'), ('call.value', 'return.value')], [('call.next', 'return.exec')])
        p['entry'] = 'wrap6'
        self.assertEqual(execute(p, {'n': 4})[0], 10)

    def test_layout_and_labels_do_not_change_code(self):
        a = recursive()
        b = copy.deepcopy(a)
        b['layout'] = {'sum/n': [999, 111], 'collapsed': ['sum']}
        b['modules']['sum']['nodes'][0]['label'] = 'a different label'
        self.assertEqual(compile_program(a)['python'], compile_program(b)['python'])
        self.assertEqual(compile_program(a)['ir_hash'], compile_program(b)['ir_hash'])

    def test_disconnect_changes_actual_model_tool_list(self):
        p = preset()
        p['modules']['main']['edges'] = [e for e in p['modules']['main']['edges'] if e['from'] != 't6.value']
        seen = []
        execute(p, {'task': 'write'}, lambda messages, tools: seen.append(tools) or {'tool': 'finish', 'args': {}})
        self.assertNotIn('fs.write', seen[0])
        self.assertIn('fs.read', seen[0])

    def test_missing_edges_block_compilation(self):
        p = preset()
        p['modules']['agent']['edges'] = [e for e in p['modules']['agent']['edges'] if e['to'] != 'branch.condition']
        self.assertFalse(compile_program(p)['ok'])

    def test_pure_cycle_rejected_but_recursion_accepted(self):
        p = recursive()
        p['modules']['sum']['edges'][0]['from'] = 'test.value'
        self.assertFalse(compile_program(p)['ok'])
        self.assertTrue(compile_program(recursive())['ok'])

    def test_exception_requires_explicit_catch(self):
        boom = graph([], 'raise', [node('msg', 'const', params={'value': 'bad'}), node('raise', 'raise')],
                     [('msg.value', 'raise.value')], [])
        main = graph([], 'call', [node('call', 'trycall', module='boom'), node('return', 'return')],
                     [('call.value', 'return.value')], [('call.next', 'return.exec')])
        p = {'formatVersion': 'module/1', 'entry': 'main', 'modules': {'main': main, 'boom': boom}}
        self.assertEqual(execute(p, {})[0], {'ok': False, 'error': 'bad'})
        main['nodes'][0]['op'] = 'call'
        with self.assertRaisesRegex(RuntimeError, 'bad'):
            execute(p, {})

    def test_removed_tool_rejected_even_if_model_requests_it(self):
        with tempfile.TemporaryDirectory() as td:
            rt = Runtime(td, td)
            rt.manifest['tools'] = ['fs.read']
            result = rt.dispatch({'tool': 'fs.write', 'args': {'path': 'x', 'content': 'bad'}}, ['fs.read'])
            self.assertFalse(result['ok'])
            self.assertFalse((Path(td) / 'x').exists())

    def test_shared_definition_change_and_frozen_code(self):
        n = node
        shared = graph([], 'r', [n('v', 'const', params={'value': 2}), n('r', 'return')], [('v.value', 'r.value')], [])
        main = graph([], 'a', [n('a', 'call', module='shared'), n('b', 'call', module='shared'), n('sum', 'add'), n('r', 'return')],
            [('a.value', 'sum.a'), ('b.value', 'sum.b'), ('sum.value', 'r.value')], [('a.next', 'b.exec'), ('b.next', 'r.exec')])
        p = {'formatVersion': 'module/1', 'entry': 'main', 'modules': {'main': main, 'shared': shared}}
        frozen = compile_program(copy.deepcopy(p))
        shared['nodes'][0]['params']['value'] = 7
        self.assertEqual(execute(p, {})[0], 14)
        with tempfile.TemporaryDirectory() as td:
            scope = {}
            exec(frozen['python'], scope)
            self.assertEqual(scope['run'](Runtime(td, td)), 4)
        independent = copy.deepcopy(shared)
        p['modules']['copy'] = independent
        main['nodes'][1]['module'] = 'copy'
        shared['nodes'][0]['params']['value'] = 9
        self.assertEqual(execute(p, {})[0], 16)

    def test_mutual_recursion(self):
        p = recursive()
        p['modules']['other'] = copy.deepcopy(p['modules']['sum'])
        next(n for n in p['modules']['sum']['nodes'] if n['id'] == 'recurse')['module'] = 'other'
        result, events = execute(p, {'n': 5})
        self.assertEqual(result, 15)
        self.assertEqual([e['moduleId'] for e in events if e['kind'] == 'enter'], ['sum', 'other', 'sum', 'other', 'sum', 'other'])

    def test_missing_model_content_is_recorded_protocol_error(self):
        with tempfile.TemporaryDirectory() as td:
            rt = Runtime(td, td)
            response = SimpleNamespace(choices=[SimpleNamespace(message=SimpleNamespace(content=None), finish_reason='length')],
                model_dump_json=lambda: '{"choices":[{"message":{"content":null},"finish_reason":"length"}]}')
            rt.client = SimpleNamespace(chat=SimpleNamespace(completions=SimpleNamespace(create=lambda **kw: response)))
            rt.model_name = 'test'
            with self.assertRaisesRegex(RuntimeError, '模型没有返回'):
                rt.model([], [])
            self.assertTrue((Path(td) / 'response-001-full.json').exists())


class PythonImportBehavior(unittest.TestCase):
    def test_source_spans_count_unicode_characters_not_utf8_bytes(self):
        source = '# 程序入口\ndef main(输入):\n    结果 = 输入 + 1\n    return 结果\n'
        program = import_source(source)
        assignment = next(node for module in program['modules'].values()
                          for node in module['nodes']
                          if node.get('sourceText') == '结果 = 输入 + 1')
        self.assertEqual(assignment['sourceSpan'], {
            'startLine': 3, 'startColumn': 4,
            'endLine': 3, 'endColumn': 15,
        })

    def test_chained_comparisons_preserve_short_circuit_and_reject_effects(self):
        source = 'def main(value, values):\n    return 0 < value < values[0] < 10\n'
        program = import_source(source)
        native = {}
        exec(source, native)
        for value, values in ((-1, []), (5, [8]), (5, [5]), (10, [11])):
            expected = native['main'](value, values)
            actual, _ = execute(program, {'value': value, 'values': values})
            self.assertEqual(actual, expected)
        effectful = (
            'def touch(value):\n    return value\n'
            'def main(values):\n    return 0 < touch(values[0]) < 10\n'
        )
        with self.assertRaisesRegex(ValueError, '链式比较中的函数调用'):
            import_source(effectful)

    def test_generator_expression_import_preserves_laziness_and_filter_order(self):
        source_path = Path(__file__).resolve().parents[2] / 'game/lesson_samples/lazy_positive_doubles.py'
        source = source_path.read_text(encoding='utf-8')
        program = import_source(source)
        native = {}
        exec(source, native)

        class TracedIterator:
            def __init__(self, values, trace):
                self.values, self.trace = list(values), trace
            def __iter__(self):
                return self
            def __next__(self):
                self.trace.append('next')
                if not self.values:
                    raise StopIteration
                return self.values.pop(0)

        class TracedIterable:
            def __init__(self, values, trace):
                self.values, self.trace = values, trace
            def __iter__(self):
                self.trace.append('iter')
                return TracedIterator(self.values, self.trace)

        native_trace, graph_trace = [], []
        native_result = native['main'](TracedIterable([-1, 0, 2, 3], native_trace))
        with tempfile.TemporaryDirectory() as td:
            runtime = Runtime(td, td)
            scope = {}
            exec(compile_program(program)['python'], scope)
            graph_result = scope['run'](runtime, values=TracedIterable([-1, 0, 2, 3], graph_trace))
            self.assertIsInstance(native_result, types.GeneratorType)
            self.assertIsInstance(graph_result, types.GeneratorType)
            self.assertEqual(native_trace, ['iter'])
            self.assertEqual(graph_trace, native_trace)
            self.assertEqual(next(native_result), 4)
            self.assertEqual(next(graph_result), 4)
            self.assertEqual(graph_trace, native_trace)
            self.assertEqual(list(native_result), [6])
            self.assertEqual(list(graph_result), [6])
            self.assertEqual(graph_trace, native_trace)
            generator_module, generator_node = next((mid, node['id'])
                for mid, module in program['modules'].items() for node in module['nodes'] if node['op'] == 'generator')
            generator_events = [event for event in runtime.events
                if event.get('moduleId') == generator_module and event.get('nodeId') == generator_node]
            self.assertEqual([event['inputs'].get('index') for event in generator_events
                              if event['kind'] == 'node' and 'index' in event.get('inputs', {})], [0, 1, 2, 3])
            self.assertEqual([event['value'] for event in generator_events if event['kind'] == 'value'], [4, 6])
        edited = copy.deepcopy(program)
        multiplier = next(node for module in edited['modules'].values() for node in module['nodes']
                          if node['op'] == 'const' and node.get('params', {}).get('value') == 2)
        multiplier['params']['value'] = 3
        changed_source = source.replace('* 2', '* 3')
        changed_python = {}
        exec(changed_source, changed_python)
        with tempfile.TemporaryDirectory() as td:
            edited_scope = {}
            exec(compile_program(edited)['python'], edited_scope)
            edited_result = edited_scope['run'](Runtime(td, td), values=[1, -2, 3])
            self.assertEqual(list(edited_result), list(changed_python['main']([1, -2, 3])))

    def test_generator_expression_rejects_effects_and_multiple_loops(self):
        cases = (
            ('def touch(value):\n    return value\ndef main(values):\n    return (touch(x) for x in values)\n',
             '生成器过滤和产出表达式不支持副作用调用'),
            ('def main(values):\n    return (x + y for x in values for y in values)\n',
             '生成器目前只支持一个同步循环和单变量目标'),
            ('def main(values):\n    factor = 2\n    result = (x * factor for x in values)\n'
             '    factor = 3\n    return result\n', '函数最终返回值'),
            ('def main(values):\n    result = (x for x in values)\n    return\n',
             '函数最终返回值'),
            ('def main(values):\n    return {"items": (x for x in values)}\n',
             '函数最终返回值'),
        )
        for source, error in cases:
            with self.subTest(error=error), self.assertRaisesRegex(ValueError, error):
                import_source(source)

    def test_agent_tool_loop_import_matches_python_and_feedback_order(self):
        source_path = Path(__file__).resolve().parents[2] / 'game/lesson_samples/agent_tool_loop.py'
        source = source_path.read_text(encoding='utf-8')
        program = import_source(source)
        graph_models, graph_dispatches = [], []

        def graph_model(messages, tools):
            conversation = copy.deepcopy(messages[1:])
            graph_models.append((conversation, list(tools)))
            return {'tool': 'world.snapshot', 'args': {}} if len(graph_models) == 1 \
                else {'tool': 'finish', 'args': {'text': conversation[-1]['content']}}

        def graph_dispatch(rt, action, tools):
            graph_dispatches.append((copy.deepcopy(action), list(tools)))
            return {'ok': True, 'observation': 'road open'}

        with patch.object(Runtime, 'dispatch', new=graph_dispatch):
            graph_value, _ = execute(program, {'task': 'inspect'}, graph_model)

        python_models, python_dispatches = [], []
        namespace = {}
        def python_message(role, value):
            return {'role': role, 'content': value if isinstance(value, str)
                    else json.dumps(value, ensure_ascii=False)}
        def python_model(messages, tools):
            python_models.append((copy.deepcopy(messages), list(tools)))
            return {'tool': 'world.snapshot', 'args': {}} if len(python_models) == 1 \
                else {'tool': 'finish', 'args': {'text': messages[-1]['content']}}
        def python_dispatch(action, tools):
            python_dispatches.append((copy.deepcopy(action), list(tools)))
            return {'ok': True, 'observation': 'road open'}
        namespace.update(message=python_message, model=python_model, dispatch=python_dispatch)
        exec(source, namespace)
        python_value = namespace['run']('inspect')

        self.assertEqual(graph_value, python_value)
        self.assertEqual(graph_models, python_models)
        self.assertEqual(graph_dispatches, python_dispatches)
        self.assertEqual(len(graph_models), 2)
        self.assertEqual(len(graph_dispatches), 1)

    def test_agent_finish_action_does_not_dispatch(self):
        source = (
            'def main(task):\n'
            '    tools = ["world.snapshot"]\n'
            '    messages = [message("user", task)]\n'
            '    action = model(messages, tools)\n'
            '    while action["tool"] != "finish":\n'
            '        messages = messages + [message("user", dispatch(action, tools))]\n'
            '        action = model(messages, tools)\n'
            '    return action["args"]["text"]\n'
        )
        program = import_source(source)
        seen_dispatches = []
        def dispatch(rt, action, tools):
            seen_dispatches.append(action)
            return {}
        with patch.object(Runtime, 'dispatch', new=dispatch):
            value, _ = execute(program, {'task': 'done'},
                               lambda messages, tools: {'tool': 'finish', 'args': {'text': 'done'}})
        self.assertEqual(value, 'done')
        self.assertEqual(seen_dispatches, [])

    def test_agent_calls_reject_conditional_effects_and_dynamic_roles(self):
        cases = (
            ('def main(task):\n    return model([], []) if task else {}\n', '条件表达式'),
            ('def main(task):\n    return message(task, "hello")\n', 'role 必须是字符串常量'),
            ('def main(model):\n    return model([], [])\n', '或模块常量覆盖'),
        )
        for source, error in cases:
            with self.subTest(error=error), self.assertRaisesRegex(ValueError, error):
                import_source(source)

    def test_import_api_then_run_executes_the_imported_python_result(self):
        source_path = Path(__file__).resolve().parents[2] / 'game/lesson_samples/class_counter.py'
        source = source_path.read_text(encoding='utf-8')
        native = {}
        exec(source, native)
        expected = native['main']()
        with tempfile.TemporaryDirectory() as td:
            state = Path(td) / 'state'
            with patch.multiple(lab_service, STATE=state, WORKSPACE=state / 'workspace',
                                RUNS=state / 'runs', PROGRAM=state / 'program.json'):
                with patch('threading.Thread.start'):
                    lab = lab_service.Lab()
                with patch.object(lab_service, 'rpc', return_value={'ok': True}):
                    imported = lab.post('/import', {'source': source, 'filename': source_path.name,
                                                     'revision': lab.revision})
                    self.assertTrue(imported['ok'])
                    started = lab.post('/run', {'task': {}})
                    self.assertTrue(started['ok'])
                    deadline = time.monotonic() + 3
                    while lab.status == 'running' and time.monotonic() < deadline:
                        time.sleep(0.01)
                    self.assertEqual(lab.status, 'complete')
                    self.assertEqual(lab.result, expected)
                    result_file = json.loads((lab.run_dir / 'result.json').read_text(encoding='utf-8'))
                    self.assertEqual(result_file['result'], expected)
                    self.assertTrue((lab.run_dir / 'program.py').is_file())
                    numeric_source = 'def main(value):\n    return value + 1\n'
                    for payload, result, result_type in (
                            ('{"task":3}', 4, int), ('{"task":3.5}', 4.5, float)):
                        imported = lab.post('/import', {'source': numeric_source, 'filename': 'numeric.py',
                                                         'revision': lab.revision})
                        self.assertTrue(imported['ok'])
                        started = lab.post('/run', json.loads(payload))
                        self.assertTrue(started['ok'])
                        deadline = time.monotonic() + 3
                        while lab.status == 'running' and time.monotonic() < deadline:
                            time.sleep(0.01)
                        self.assertEqual(lab.status, 'complete')
                        self.assertEqual(lab.result, result)
                        self.assertIs(type(lab.result), result_type)

    def test_http_import_run_preserves_input_number_types(self):
        with tempfile.TemporaryDirectory() as td:
            state = Path(td) / 'state'
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

            with patch.multiple(lab_service, STATE=state, WORKSPACE=state / 'workspace',
                                RUNS=Path(td) / 'runs', PROGRAM=state / 'program.json'), \
                    patch.object(lab_service, 'ThreadingHTTPServer', IsolatedServer), \
                    patch.object(threading.Thread, 'start', start_without_sync_loop), \
                    patch.object(lab_service, 'rpc', return_value={'ok': True}):
                with patch('builtins.print'):
                    lab_service.main()
                base = 'http://127.0.0.1:%d' % IsolatedServer.port

                def get(path):
                    with urllib.request.urlopen(base + path, timeout=2) as response:
                        return json.load(response)

                def post(path, body):
                    request = urllib.request.Request(base + path, data=body.encode('utf-8'),
                        headers={'Content-Type': 'application/json'})
                    with urllib.request.urlopen(request, timeout=2) as response:
                        return json.load(response)

                try:
                    current = get('/program')
                    imported = post('/import', json.dumps({'source': 'def main(value):\n    return value + 1\n',
                        'filename': 'numeric.py', 'revision': current['revision']}))
                    self.assertTrue(imported['ok'])
                    for body, expected, expected_type in (
                            ('{"task":3}', 4, int), ('{"task":3.5}', 4.5, float)):
                        started = post('/run', body)
                        self.assertTrue(started['ok'])
                        deadline = time.monotonic() + 3
                        result = get('/state')
                        while result['status'] == 'running' and time.monotonic() < deadline:
                            time.sleep(0.01)
                            result = get('/state')
                        self.assertEqual(result['status'], 'complete')
                        self.assertEqual(result['result'], expected)
                        self.assertIs(type(result['result']), expected_type)
                    source_path = Path(__file__).resolve().parents[2] / 'game/lesson_samples/agent_tool_loop.py'
                    agent_source = source_path.read_text(encoding='utf-8')
                    agent_models, agent_dispatches = [], []
                    def model(rt, messages, tools):
                        agent_models.append((copy.deepcopy(messages), list(tools)))
                        if len(agent_models) == 1:
                            return {'tool': 'world.snapshot', 'args': {}}
                        return {'tool': 'finish', 'args': {'text': messages[-1]['content']}}
                    def dispatch(rt, action, tools):
                        agent_dispatches.append((copy.deepcopy(action), list(tools)))
                        return {'ok': True, 'observation': 'road open'}
                    with patch.object(Runtime, 'model', new=model), patch.object(Runtime, 'dispatch', new=dispatch):
                        current = get('/program')
                        imported = post('/import', json.dumps({'source': agent_source,
                            'filename': source_path.name, 'revision': current['revision']}))
                        self.assertTrue(imported['ok'])
                        started = post('/run', json.dumps({'task': 'inspect'}))
                        self.assertTrue(started['ok'])
                        deadline = time.monotonic() + 3
                        result = get('/state')
                        while result['status'] == 'running' and time.monotonic() < deadline:
                            time.sleep(0.01)
                            result = get('/state')
                        self.assertEqual(result['status'], 'complete')
                        self.assertEqual(result['result'], '{"ok": true, "observation": "road open"}')
                        self.assertEqual(len(agent_models), 2)
                        self.assertEqual(len(agent_dispatches), 1)
                        self.assertEqual(agent_dispatches[0][0], {'tool': 'world.snapshot', 'args': {}})
                        self.assertEqual(agent_models[1][0][-1]['content'],
                                         '{"ok": true, "observation": "road open"}')
                    generator_path = Path(__file__).resolve().parents[2] / 'game/lesson_samples/lazy_positive_doubles.py'
                    generator_source = generator_path.read_text(encoding='utf-8')
                    current = get('/program')
                    imported = post('/import', json.dumps({'source': generator_source,
                        'filename': generator_path.name, 'revision': current['revision']}))
                    self.assertTrue(imported['ok'])
                    started = post('/run', json.dumps({'task': [1, -2, 3]}))
                    self.assertTrue(started['ok'])
                    deadline = time.monotonic() + 3
                    result = get('/state')
                    while result['status'] == 'running' and time.monotonic() < deadline:
                        time.sleep(0.01)
                        result = get('/state')
                    self.assertEqual(result['status'], 'complete')
                    self.assertEqual(result['result'], [2, 6])
                    saved = json.loads((Path(td) / 'runs' / result['runId'] / 'result.json')
                                       .read_text(encoding='utf-8'))
                    self.assertEqual(saved['result'], [2, 6])
                    current = get('/program')
                    edited = copy.deepcopy(current['program'])
                    multiplier = next(node for module in edited['modules'].values()
                                      for node in module['nodes']
                                      if node['op'] == 'const' and node.get('params', {}).get('value') == 2)
                    multiplier['params']['value'] = 3
                    saved_edit = post('/program', json.dumps({'program': edited,
                        'revision': current['revision']}))
                    self.assertTrue(saved_edit['ok'])
                    self.assertTrue(saved_edit['validation']['ok'])
                    started = post('/run', json.dumps({'task': [1, -2, 3]}))
                    self.assertTrue(started['ok'])
                    deadline = time.monotonic() + 3
                    result = get('/state')
                    while result['status'] == 'running' and time.monotonic() < deadline:
                        time.sleep(0.01)
                        result = get('/state')
                    changed_python = {}
                    exec(generator_source.replace('* 2', '* 3'), changed_python)
                    self.assertEqual(result['status'], 'complete')
                    self.assertEqual(result['result'], list(changed_python['main']([1, -2, 3])))
                    self.assertEqual(result['result'], [3, 9])
                    frozen = json.loads((Path(td) / 'runs' / result['runId'] / 'program.json')
                                        .read_text(encoding='utf-8'))
                    self.assertEqual(multiplier['params']['value'], 3)
                    self.assertTrue(any(node['op'] == 'const' and node.get('params', {}).get('value') == 3
                                        for module in frozen['modules'].values() for node in module['nodes']))
                    list_source = 'def main(values):\n    return [x * 2 for x in values if x > 0]\n'
                    current = get('/program')
                    self.assertTrue(post('/import', json.dumps({'source': list_source, 'filename': 'list.py',
                        'revision': current['revision']}))['ok'])
                    current = get('/program')
                    graph = copy.deepcopy(current['program'])
                    multiplier = next(node for module in graph['modules'].values() for node in module['nodes']
                                      if node['op'] == 'const' and node.get('params', {}).get('value') == 2)
                    multiplier['params']['value'] = 3
                    self.assertTrue(post('/program', json.dumps({'program': graph,
                        'revision': current['revision']}))['validation']['ok'])
                    started = post('/run', json.dumps({'task': [1, -2, 3]}))
                    self.assertTrue(started['ok'])
                    deadline = time.monotonic() + 3
                    result = get('/state')
                    while result['status'] == 'running' and time.monotonic() < deadline:
                        time.sleep(0.01)
                        result = get('/state')
                    native = {}
                    exec(list_source.replace('* 2', '* 3'), native)
                    self.assertEqual(result['status'], 'complete')
                    self.assertEqual(result['result'], native['main']([1, -2, 3]))
                    list_ids = {node['id'] for module in graph['modules'].values()
                                for node in module['nodes'] if node['op'] == 'listcomp'}
                    self.assertEqual([event['inputs']['index'] for event in result['events']
                                      if event.get('nodeId') in list_ids and event['kind'] == 'node'
                                      and 'index' in event.get('inputs', {})], [0, 1, 2])
                    score_path = Path(__file__).resolve().parents[2] / 'game/lesson_samples/editable_score_map.py'
                    score_source = score_path.read_text(encoding='utf-8')
                    current = get('/program')
                    imported = post('/import', json.dumps({'source': score_source,
                        'filename': score_path.name, 'revision': current['revision']}))
                    self.assertTrue(imported['ok'])
                    current = get('/program')
                    graph = copy.deepcopy(current['program'])
                    multiplier = next(node for module in graph['modules'].values() for node in module['nodes']
                                      if node['op'] == 'const' and node.get('params', {}).get('value') == 2)
                    multiplier['params']['value'] = 3
                    self.assertTrue(post('/program', json.dumps({'program': graph,
                        'revision': current['revision']}))['validation']['ok'])
                    started = post('/run', json.dumps({'task': [1, -2, 3]}))
                    self.assertTrue(started['ok'])
                    deadline = time.monotonic() + 3
                    result = get('/state')
                    while result['status'] == 'running' and time.monotonic() < deadline:
                        time.sleep(0.01)
                        result = get('/state')
                    changed_python = {}
                    exec(score_source.replace('value * 2', 'value * 3'), changed_python)
                    self.assertEqual(result['status'], 'complete')
                    self.assertEqual(result['result'], changed_python['main']([1, -2, 3]))
                    self.assertEqual(result['result'], {'value-01': 3, 'value-03': 9})
                    dict_ids = {node['id'] for module in graph['modules'].values()
                                for node in module['nodes'] if node['op'] == 'dictcomp'}
                    self.assertEqual([event['inputs']['index'] for event in result['events']
                                      if event.get('nodeId') in dict_ids and event['kind'] == 'node'
                                      and 'index' in event.get('inputs', {})], [0, 1, 2])
                finally:
                    IsolatedServer.server.shutdown()
                    IsolatedServer.server.server_close()
                    IsolatedServer.worker.join(timeout=1)

    def test_module_constants_cannot_shadow_lowered_calls(self):
        cases = {
            'sum': ('sum = 5\ndef main(values):\n    return sum(values)\n', ([1, 2],)),
            'read': ('read = 5\ndef main(path):\n    return read(path)\n', ('input.txt',)),
            'write': ('write = 5\ndef main(path):\n    write(path, "x")\n    return None\n', ('output.txt',)),
            'open': ('open = 5\ndef main(path):\n    with open(path) as file:\n        return file.read()\n', ('input.txt',)),
            'ZeroDivisionError': (
                'ZeroDivisionError = 5\ndef main(value):\n    try:\n        return 1 / value\n'
                '    except ZeroDivisionError:\n        return 0\n', (0,)),
            'ZeroDivisionError function': (
                'def ZeroDivisionError():\n    return 5\ndef main(value):\n    try:\n'
                '        return 1 / value\n    except ZeroDivisionError:\n        return 0\n', (0,)),
            'ZeroDivisionError local': (
                'def main(ZeroDivisionError, value):\n    try:\n        return 1 / value\n'
                '    except ZeroDivisionError:\n        return 0\n', (5, 0)),
        }
        for name, (source, arguments) in cases.items():
            with self.subTest(name=name):
                native = {}
                exec(source, native)
                with self.assertRaises(TypeError):
                    native['main'](*arguments)
                with self.assertRaises(ValueError):
                    import_source(source)

    def test_short_circuit_file_effects_are_rejected(self):
        cases = {
            'and write': (
                "def main(path):\n    return False and write(path, 'x')\n", False),
            'conditional read': (
                "def main(path):\n    return read(path) if False else 'fallback'\n", 'fallback'),
        }
        for name, (source, expected) in cases.items():
            with self.subTest(name=name):
                native = {}
                exec(source, native)
                with tempfile.TemporaryDirectory() as td:
                    old_cwd = os.getcwd()
                    try:
                        os.chdir(td)
                        self.assertEqual(native['main']('missing.txt'), expected)
                    finally:
                        os.chdir(old_cwd)
                    self.assertFalse((Path(td) / 'missing.txt').exists())
                with self.assertRaisesRegex(ValueError, '短路表达式|条件表达式'):
                    import_source(source)

    def test_with_open_does_not_capture_top_level_helper_names(self):
        sources = {
            'function': (
                'def read(path):\n'
                '    return "fake"\n'
                'def main(path):\n'
                '    with open(path) as file:\n'
                '        return file.read()\n'),
            'constant': (
                'read = 5\n'
                'def main(path):\n'
                '    with open(path) as file:\n'
                '        return file.read()\n'),
        }
        for name, source in sources.items():
            with self.subTest(name=name):
                native = {}
                exec(source, native)
                compiled = compile_program(import_source(source))
                self.assertTrue(compiled['ok'], compiled['errors'])
                with tempfile.TemporaryDirectory() as td:
                    (Path(td) / 'input.txt').write_text('actual file content', encoding='utf-8')
                    old_cwd = os.getcwd()
                    try:
                        os.chdir(td)
                        expected = native['main']('input.txt')
                    finally:
                        os.chdir(old_cwd)
                    scope = {}
                    exec(compiled['python'], scope)
                    actual = scope['run'](Runtime(td, td), path='input.txt')
                self.assertEqual(actual, expected)
                self.assertEqual(actual, 'actual file content')

    def test_with_open_rejects_shadowed_open_function(self):
        source = (
            'def open(path):\n'
            '    return None\n'
            'def main(path):\n'
            '    with open(path) as file:\n'
            '        return file.read()\n'
        )
        native = {}
        exec(source, native)
        with self.assertRaises(TypeError):
            native['main']('input.txt')
        with self.assertRaises(ValueError):
            import_source(source)

    def test_class_field_cannot_share_a_method_name(self):
        source = (
            'class Counter:\n'
            '    def __init__(self):\n'
            '        self.inc = 0\n'
            '    def inc(self):\n'
            '        return 2\n'
            '    def call(self):\n'
            '        return self.inc()\n'
            'def main():\n'
            '    counter = Counter()\n'
            '    return counter.call()\n'
        )
        native = {}
        exec(source, native)
        with self.assertRaises(TypeError):
            native['main']()
        with self.assertRaisesRegex(ValueError, '字段和方法不能同名'):
            import_source(source)

    def test_python_special_methods_are_not_lowered_as_plain_methods(self):
        cases = {
            '__setattr__': (
                'class Counter:\n'
                '    def __init__(self):\n'
                '        self.n = 1\n'
                '    def __setattr__(self, name, value):\n'
                '        return None\n'
                '    def read(self):\n'
                '        return self.n\n'
                'def main():\n'
                '    counter = Counter()\n'
                '    return counter.read()\n', AttributeError),
            '__new__': (
                'class Counter:\n'
                '    def __new__(cls):\n'
                '        return 5\n'
                '    def __init__(self):\n'
                '        self.n = 1\n'
                '    def read(self):\n'
                '        return self.n\n'
                'def main():\n'
                '    counter = Counter()\n'
                '    return counter.read()\n', AttributeError),
        }
        for name, (source, error) in cases.items():
            with self.subTest(name=name):
                native = {}
                exec(source, native)
                with self.assertRaises(error):
                    native['main']()
                with self.assertRaisesRegex(ValueError, 'Python 特殊方法'):
                    import_source(source)

        private_field = (
            'class Counter:\n'
            '    def __init__(self):\n'
            '        self.__n = 1\n'
            'def main():\n'
            '    counter = Counter()\n'
            '    return counter.__n\n'
        )
        native = {}
        exec(private_field, native)
        with self.assertRaises(AttributeError):
            native['main']()
        with self.assertRaisesRegex(ValueError, '双下划线实例字段'):
            import_source(private_field)

        for attribute, error in (('__dict__', TypeError), ('__class__', TypeError),
                                 ('__weakref__', AttributeError)):
            with self.subTest(attribute=attribute):
                source = (
                    'class Counter:\n'
                    '    def __init__(self):\n'
                    '        self.' + attribute + ' = 5\n'
                    'def main():\n'
                    '    return Counter()\n'
                )
                native = {}
                exec(source, native)
                with self.assertRaises(error):
                    native['main']()
                with self.assertRaisesRegex(ValueError, '双下划线实例字段'):
                    import_source(source)

    def test_class_import_executes_and_graph_edit_preserves_python_result(self):
        sample = Path(__file__).resolve().parents[2] / 'game/lesson_samples/class_counter.py'
        source = sample.read_text(encoding='utf-8')
        native = {}
        exec(source, native)
        program = import_source(source)
        for _ in range(2):
            self.assertEqual(execute(copy.deepcopy(program), {})[0], native['main']())

        edited_source = source.replace('self.n = 0', 'self.n = 3')
        edited_native = {}
        exec(edited_source, edited_native)
        edited_program = copy.deepcopy(program)
        for module in edited_program['modules'].values():
            for item in module.get('nodes', []):
                if item['op'] == 'const' and item.get('params', {}).get('value') == 0:
                    item['params']['value'] = 3
        for _ in range(2):
            self.assertEqual(execute(copy.deepcopy(edited_program), {})[0], edited_native['main']())


if __name__ == '__main__':
    unittest.main()
