"""Lower a small Python teaching subset into a read-only 3D program graph."""
import ast
import json
from pathlib import Path
import sys


class PythonVisualIR:
    def __init__(self, source: str):
        self.source = source
        self.tree = ast.parse(source)
        if len(self.tree.body) != 1 or not isinstance(self.tree.body[0], ast.FunctionDef):
            raise ValueError('只支持一个普通 Python 函数')
        self.function = self.tree.body[0]
        if self.function.decorator_list or self.function.args.vararg or self.function.args.kwarg:
            raise ValueError('函数不能含装饰器或可变参数')
        if self.function.args.posonlyargs or self.function.args.kwonlyargs or self.function.args.defaults:
            raise ValueError('函数只支持普通位置参数，且不带默认值')
        self.serial = 0
        self.modules: dict[str, dict] = {}
        self.layouts: dict[str, dict] = {}

    def build(self) -> dict:
        function_inputs = [arg.arg for arg in self.function.args.args]
        if len(function_inputs) != 2:
            raise ValueError('当前教学样例函数需要两个参数')
        function_module = self._scope(
            self.function.name, self.function.body, function_inputs, 'function',
            {'values': [4, 2, 7, 2], 'target': 2})

        nodes = []
        edges = []
        for name, value in zip(function_inputs, ([4, 2, 7, 2], 2)):
            node_id = self._id('input')
            params = {'name': name, 'previewValue': value}
            nodes.append({'id': node_id, 'op': 'input', 'params': params, 'sourceText': name})
            edges.append({'from': node_id + '.value', 'to': 'find_index.' + name})
        nodes.append({
            'id': 'find_index', 'op': 'call', 'module': self.function.name,
            'params': {'visualExtent': [6.0, 1.5, 4.5]},
            'sourceText': self._first_line(self.function),
        })
        self.modules['program'] = {
            'kind': 'program', 'label': 'Python 样例', 'inputs': [],
            'entry': 'find_index', 'nodes': nodes, 'edges': edges,
        }
        self.layouts['program'] = {'positions': {
            nodes[0]['id']: [-5.0, 0.0, -1.5],
            nodes[1]['id']: [-5.0, 0.0, 1.5],
            'find_index': [1.0, 0.0, 0.0],
        }}
        return {
            'formatVersion': 'python-preview/1',
            'displayOnly': True,
            'sourceFile': 'res://lesson_samples/linear_search.py',
            'source': self.source,
            'entry': 'program',
            'modules': self.modules,
            'machineLayout': self.layouts,
        }

    def _scope(self, module_id: str, statements: list[ast.stmt], input_names: list[str],
               kind: str, preview_values: dict | None = None, in_loop: bool = False) -> dict:
        nodes: list[dict] = []
        edges: list[dict] = []
        symbols: list[dict] = []
        environment: dict[str, str] = {}
        for name in input_names:
            node_id = self._id('input')
            params = {'name': name}
            if preview_values and name in preview_values:
                params['previewValue'] = preview_values[name]
            nodes.append({'id': node_id, 'op': 'input', 'params': params, 'sourceText': name})
            environment[name] = node_id
            symbols.append({'name': name, 'kind': 'parameter'})

        entry, _ = self._statements(module_id, statements, nodes, edges, environment, in_loop)
        if not entry:
            raise ValueError('函数体不能为空')
        module = {
            'kind': kind, 'language': 'python', 'label': module_id,
            'inputs': input_names, 'scope': {'symbols': symbols},
            'entry': entry, 'nodes': nodes, 'edges': edges,
        }
        self.modules[module_id] = module
        return module

    def _statements(self, module_id: str, statements: list[ast.stmt], nodes: list[dict],
                    edges: list[dict], environment: dict[str, str], in_loop: bool) -> tuple[str, str]:
        previous = ''
        first = ''
        for index, statement in enumerate(statements):
            if isinstance(statement, ast.Assign):
                if len(statement.targets) != 1 or not isinstance(statement.targets[0], ast.Name):
                    raise self._unsupported(statement, '赋值只支持单个变量目标')
                inputs = self._names(statement.value)
                missing = [name for name in inputs if name not in environment]
                if missing:
                    raise self._unsupported(statement, '变量尚未定义：' + ', '.join(missing))
                expression_id = self._id('expression')
                expression = self._expression_module(expression_id, statement.value)
                self.modules[expression_id] = expression
                node_id = self._id('statement')
                node = {
                    'id': node_id, 'op': 'statement', 'module': expression_id,
                    'params': {'kind': 'assign', 'target': statement.targets[0].id},
                    'sourceText': self._first_line(statement),
                }
                nodes.append(node)
                self._wire_names(edges, environment, node_id, inputs)
                if previous:
                    edges.append({'from': previous + '.next', 'to': node_id + '.exec'})
                if not first:
                    first = node_id
                previous = node_id
                environment[statement.targets[0].id] = node_id
            elif isinstance(statement, ast.For):
                target_names = self._target_names(statement.target)
                if not (isinstance(statement.iter, ast.Call)
                        and isinstance(statement.iter.func, ast.Name)
                        and statement.iter.func.id == 'enumerate'
                        and len(statement.iter.args) == 1 and not statement.iter.keywords
                        and len(target_names) == 2):
                    raise self._unsupported(statement, '循环当前支持 for index, value in enumerate(sequence)')
                iterable_names = self._names(statement.iter.args[0])
                body_names = self._names(statement)
                outer_names = sorted((set(iterable_names) | set(body_names)) - set(target_names))
                missing = [name for name in outer_names if name not in environment]
                if missing:
                    raise self._unsupported(statement, '循环读取未定义变量：' + ', '.join(missing))
                loop_id = self._id('loop')
                body_module_id = self._id('loop_body')
                body_inputs = target_names + [name for name in outer_names if name not in target_names]
                self._scope(body_module_id, statement.body, body_inputs, 'scope', in_loop=True)
                node_id = self._id('for')
                visual_inputs = sorted(set(outer_names))
                node = {
                    'id': node_id, 'op': 'for', 'module': body_module_id,
                    'params': {
                        'visualInputs': visual_inputs,
                        'target': ', '.join(target_names),
                        'iter': ast.unparse(statement.iter),
                        'visualExtent': [2.75, 1.25, 2.25],
                    },
                    'sourceText': self._first_line(statement),
                }
                nodes.append(node)
                self._wire_names(edges, environment, node_id, visual_inputs)
                if previous:
                    edges.append({'from': previous + '.next', 'to': node_id + '.exec'})
                if not first:
                    first = node_id
                previous = node_id
                for name in self._assigned_names(statement.body):
                    environment[name] = node_id
            elif isinstance(statement, ast.If):
                if index != len(statements) - 1:
                    raise self._unsupported(statement, '当前预览子集要求 if 是所在代码块的最后一项')
                condition_names = self._names(statement.test)
                missing = [name for name in condition_names if name not in environment]
                if missing:
                    raise self._unsupported(statement, '条件读取未定义变量：' + ', '.join(missing))
                condition_id = self._id('condition')
                self.modules[condition_id] = self._expression_module(condition_id, statement.test)
                branch_id = self._id('branch')
                nodes.append({
                    'id': branch_id, 'op': 'branch', 'module': condition_id,
                    'params': {'visualExtent': [2.75, 1.25, 2.25]},
                    'sourceText': self._first_line(statement),
                })
                self._wire_names(edges, environment, branch_id, condition_names)
                if previous:
                    edges.append({'from': previous + '.next', 'to': branch_id + '.exec'})
                if not first:
                    first = branch_id
                then_entry, _ = self._statements(module_id, statement.body, nodes, edges,
                                                 dict(environment), in_loop)
                if then_entry:
                    edges.append({'from': branch_id + '.then', 'to': then_entry + '.exec'})
                else:
                    then_id = self._id('continue' if in_loop else 'empty')
                    nodes.append({'id': then_id, 'op': 'continue' if in_loop else 'nop'})
                    edges.append({'from': branch_id + '.then', 'to': then_id + '.exec'})
                if statement.orelse:
                    else_entry, _ = self._statements(module_id, statement.orelse, nodes, edges,
                                                     dict(environment), in_loop)
                else:
                    else_entry = self._id('continue' if in_loop else 'empty')
                    nodes.append({'id': else_entry, 'op': 'continue' if in_loop else 'nop'})
                edges.append({'from': branch_id + '.else', 'to': else_entry + '.exec'})
                for name in self._assigned_names(statement.body + statement.orelse):
                    environment[name] = branch_id
                previous = ''
            elif isinstance(statement, ast.Break):
                if not in_loop:
                    raise self._unsupported(statement, 'break 必须位于循环内部')
                node_id = self._id('break')
                nodes.append({'id': node_id, 'op': 'break', 'sourceText': self._first_line(statement)})
                if previous:
                    edges.append({'from': previous + '.next', 'to': node_id + '.exec'})
                if not first:
                    first = node_id
                previous = ''
            elif isinstance(statement, ast.Return):
                if statement.value is None:
                    raise self._unsupported(statement, 'return 必须带返回值')
                inputs = self._names(statement.value)
                missing = [name for name in inputs if name not in environment]
                if missing:
                    raise self._unsupported(statement, 'return 读取未定义变量：' + ', '.join(missing))
                expression_id = self._id('expression_return')
                self.modules[expression_id] = self._expression_module(expression_id, statement.value)
                node_id = self._id('return')
                nodes.append({
                    'id': node_id, 'op': 'return', 'module': expression_id,
                    'sourceText': self._first_line(statement),
                })
                self._wire_names(edges, environment, node_id, inputs)
                if previous:
                    edges.append({'from': previous + '.next', 'to': node_id + '.exec'})
                if not first:
                    first = node_id
                previous = node_id
            else:
                raise self._unsupported(statement, '暂不支持此语句')
        return first, previous

    def _expression_module(self, module_id: str, expression: ast.expr) -> dict:
        names = self._names(expression)
        nodes = []
        edges = []
        values = {}
        for name in names:
            node_id = self._id('input')
            nodes.append({'id': node_id, 'op': 'input', 'params': {'name': name}, 'sourceText': name})
            values[name] = node_id
        result = self._expression(expression, nodes, edges, values)
        return_id = self._id('return')
        nodes.append({'id': return_id, 'op': 'return'})
        edges.append({'from': result + '.value', 'to': return_id + '.value'})
        return {
            'kind': 'expression', 'label': ast.unparse(expression),
            'inputs': names, 'entry': return_id, 'nodes': nodes, 'edges': edges,
        }

    def _expression(self, expression: ast.expr, nodes: list[dict], edges: list[dict],
                    inputs: dict[str, str]) -> str:
        if isinstance(expression, ast.Name):
            if expression.id not in inputs:
                raise self._unsupported(expression, '变量未声明：' + expression.id)
            return inputs[expression.id]
        if isinstance(expression, ast.Constant) and type(expression.value) in (int, float, str, bool):
            return self._append_node(nodes, 'const', {'value': expression.value}, self._segment(expression))
        if isinstance(expression, ast.UnaryOp) and isinstance(expression.op, ast.USub) \
                and isinstance(expression.operand, ast.Constant) and type(expression.operand.value) in (int, float):
            return self._append_node(nodes, 'const', {'value': -expression.operand.value}, self._segment(expression))
        if isinstance(expression, ast.BinOp):
            operators = {ast.Add: ('add', 'a', 'b'), ast.Sub: ('sub', 'a', 'b'), ast.Mult: ('mul', 'a', 'b')}
            spec = operators.get(type(expression.op))
            if not spec:
                raise self._unsupported(expression, '表达式只支持 +、-、*')
            left = self._expression(expression.left, nodes, edges, inputs)
            right = self._expression(expression.right, nodes, edges, inputs)
            node_id = self._append_node(nodes, spec[0], {}, self._segment(expression))
            edges.extend([
                {'from': left + '.value', 'to': node_id + '.' + spec[1]},
                {'from': right + '.value', 'to': node_id + '.' + spec[2]},
            ])
            return node_id
        if isinstance(expression, ast.Compare) and len(expression.ops) == 1 and len(expression.comparators) == 1:
            operator = {ast.Eq: ('eq', 'a', 'b'), ast.Lt: ('lt', 'a', 'b')}.get(type(expression.ops[0]))
            if not operator:
                raise self._unsupported(expression, '比较只支持 == 和 <')
            left = self._expression(expression.left, nodes, edges, inputs)
            right = self._expression(expression.comparators[0], nodes, edges, inputs)
            node_id = self._append_node(nodes, operator[0], {}, self._segment(expression))
            edges.extend([
                {'from': left + '.value', 'to': node_id + '.' + operator[1]},
                {'from': right + '.value', 'to': node_id + '.' + operator[2]},
            ])
            return node_id
        raise self._unsupported(expression, '暂不支持此表达式')

    def _append_node(self, nodes: list[dict], op: str, params: dict, source_text: str) -> str:
        node_id = self._id(op)
        node = {'id': node_id, 'op': op}
        if params:
            node['params'] = params
        if source_text:
            node['sourceText'] = source_text
        nodes.append(node)
        return node_id

    @staticmethod
    def _wire_names(edges: list[dict], environment: dict[str, str], target_id: str,
                    names: list[str]) -> None:
        for name in names:
            edges.append({'from': environment[name] + '.value', 'to': target_id + '.' + name})

    @staticmethod
    def _names(node: ast.AST) -> list[str]:
        return sorted({item.id for item in ast.walk(node)
                       if isinstance(item, ast.Name) and isinstance(item.ctx, ast.Load)
                       and item.id not in {'enumerate'}})

    @staticmethod
    def _target_names(target: ast.expr) -> list[str]:
        if isinstance(target, ast.Name):
            return [target.id]
        if isinstance(target, ast.Tuple) and all(isinstance(item, ast.Name) for item in target.elts):
            return [item.id for item in target.elts]
        raise ValueError('循环目标只支持变量或变量元组')

    @staticmethod
    def _assigned_names(statements: list[ast.stmt]) -> list[str]:
        names = set()
        for statement in statements:
            for node in ast.walk(statement):
                if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Store):
                    names.add(node.id)
        return sorted(names)

    def _segment(self, node: ast.AST) -> str:
        return ast.get_source_segment(self.source, node) or ast.unparse(node)

    def _first_line(self, node: ast.AST) -> str:
        return self._segment(node).splitlines()[0].strip()

    def _unsupported(self, node: ast.AST, message: str) -> ValueError:
        return ValueError('第 %s 行：%s' % (getattr(node, 'lineno', '?'), message))

    def _id(self, prefix: str) -> str:
        self.serial += 1
        return '%s_%d' % (prefix, self.serial)


def main() -> None:
    if len(sys.argv) not in (2, 3):
        raise SystemExit('用法: python python_visual_ir.py <source.py> [output.json]')
    source_path = Path(sys.argv[1]).resolve()
    output_path = Path(sys.argv[2]).resolve() if len(sys.argv) == 3 else source_path.with_suffix('.json')
    program = PythonVisualIR(source_path.read_text(encoding='utf-8')).build()
    program['sourceFile'] = 'res://lesson_samples/' + source_path.name
    output_path.write_text(json.dumps(program, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print('PYTHON VISUAL IR WRITTEN', output_path)


if __name__ == '__main__':
    main()
