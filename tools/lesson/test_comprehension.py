"""CPython parity for imported eager comprehensions."""
import unittest
from pathlib import Path

from import_python import import_source
from test_agent_lab import execute


class PythonComprehensionAcceptance(unittest.TestCase):
    def test_list_comprehensions_match_python_and_keep_iteration_events(self):
        source = 'def main(values):\n    return [x * 2 for x in values if x > 0] + [x * 3 for x in values if x > 0]\n'
        program = import_source(source)
        self.assertEqual(program['exampleTask'], [1, 2, 3])
        native = {}
        exec(source, native)

        class TracedIterable:
            def __init__(self, values, trace):
                self.values, self.trace = list(values), trace
            def __iter__(self):
                self.trace.append('iter')
                self.iterator = iter(self.values)
                return self
            def __next__(self):
                self.trace.append('next')
                return next(self.iterator)

        native_trace, graph_trace = [], []
        values = [1, -2, 3]
        expected = native['main'](TracedIterable(values, native_trace))
        actual, events = execute(program, {'values': TracedIterable(values, graph_trace)})
        self.assertIs(type(actual), list)
        self.assertEqual(actual, expected)
        self.assertEqual(actual, [2, 6, 3, 9])
        self.assertEqual(graph_trace, native_trace)
        list_nodes = {node['id'] for module in program['modules'].values()
                      for node in module['nodes'] if node['op'] == 'listcomp'}
        indexes = [event['inputs']['index'] for event in events if event.get('nodeId') in list_nodes
                   and event['kind'] == 'node' and 'index' in event.get('inputs', {})]
        self.assertEqual(indexes, [0, 1, 2, 0, 1, 2])
        input_nodes = [node['id'] for module in program['modules'].values()
                       for node in module['nodes'] if node['op'] == 'generator_input']
        self.assertEqual([sum(event.get('nodeId') == node and event['kind'] == 'value' for event in events)
                          for node in input_nodes], [3, 3])

    def test_f_strings_match_python_and_keep_editable_text_and_values(self):
        source = ('def main(value):\n'
                  '    return f"amount={value:04d}; repr={value!r}; {{ok}}"\n')
        program = import_source(source)
        native = {}
        exec(source, native)
        actual, _ = execute(program, {'value': 7})
        self.assertEqual(actual, native['main'](7))
        self.assertEqual(actual, 'amount=0007; repr=7; {ok}')
        format_nodes = [node for module in program['modules'].values() for node in module['nodes']
                        if node['op'] == 'format']
        self.assertEqual(len(format_nodes), 2)
        for module in program['modules'].values():
            for node in module['nodes']:
                if node['op'] == 'const' and node.get('params', {}).get('value') == 'amount=':
                    node['params']['value'] = 'total='
        edited, _ = execute(program, {'value': 7})
        self.assertEqual(edited, native['main'](7).replace('amount=', 'total='))
        conversions = 'def main(value):\n    return f"{value!s:>5}|{value!a}"\n'
        converted, _ = execute(import_source(conversions), {'value': '猫'})
        converted_native = {}
        exec(conversions, converted_native)
        self.assertEqual(converted, converted_native['main']('猫'))

    def test_f_strings_reject_effectful_interpolation_and_dynamic_format_specs(self):
        effectful = ('def helper():\n    return 1\n'
                     'def main():\n    return f"{helper()}"\n')
        dynamic = ('def main(value, width):\n'
                   '    return f"{value:{width}d}"\n')
        with self.assertRaisesRegex(ValueError, '函数调用或文件读写尚不支持'):
            import_source(effectful)
        with self.assertRaisesRegex(ValueError, '格式说明只支持字符串常量'):
            import_source(dynamic)

    def test_dict_comprehensions_match_python_and_run_after_graph_edits(self):
        source_path = Path(__file__).resolve().parents[2] / 'game/lesson_samples/editable_score_map.py'
        source = source_path.read_text(encoding='utf-8')
        program = import_source(source)
        dict_nodes = [node for module in program['modules'].values() for node in module['nodes']
                      if node['op'] == 'dictcomp']
        self.assertEqual(len(dict_nodes), 1)
        native = {}
        exec(source, native)

        class TracedIterable:
            def __init__(self, values, trace):
                self.values, self.trace = list(values), trace
            def __iter__(self):
                self.trace.append('iter')
                self.iterator = iter(self.values)
                return self
            def __next__(self):
                self.trace.append('next')
                return next(self.iterator)

        values = [2, -1, 3]
        native_trace, graph_trace = [], []
        expected = native['main'](TracedIterable(values, native_trace))
        actual, _ = execute(program, {'values': TracedIterable(values, graph_trace)})
        self.assertEqual(list(actual.items()), list(expected.items()))
        self.assertEqual(graph_trace, native_trace)
        self.assertEqual(actual, {'value-02': 4, 'value-03': 6})
        for module in program['modules'].values():
            for node in module['nodes']:
                if node['op'] == 'const' and node.get('params', {}).get('value') == 2:
                    node['params']['value'] = 3
        edited, _ = execute(program, {'values': values})
        edited_source = source.replace('value * 2', 'value * 3')
        edited_native = {}
        exec(edited_source, edited_native)
        self.assertEqual(list(edited.items()), list(edited_native['main'](values).items()))


if __name__ == '__main__':
    unittest.main()
