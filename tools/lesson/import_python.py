"""Import supported Python semantics as editable native module/1 graph nodes."""
import ast, json, math, sys
from pathlib import Path
import urllib.error, urllib.request

from class_lowering import lower_classes
from expression_lowering import AGENT_CALLS, lower_chained_comparison, lower_expression
from expression_analysis import expression_names

class PythonSubset:
    def __init__(self, source, function, registry, module_id, constants):
        self.source = source
        self.source_lines = source.splitlines()
        self.function = function
        self.registry = registry
        self.module_id = module_id
        self.constants = constants
        if self.function.decorator_list:
            raise ValueError(self._line(self.function) + '不支持函数装饰器')
        args = self.function.args
        if (args.posonlyargs or args.defaults or args.kwonlyargs
                or args.kw_defaults or args.vararg or args.kwarg
                or self.function.returns is not None or any(arg.annotation is not None for arg in args.args)):
            raise ValueError(self._line(self.function) + '当前只支持无默认值、无注解的位置参数')
        self.input_names = [arg.arg for arg in args.args]
        self.shadowed_names = set(self.input_names)
        for statement in ast.walk(self.function):
            if isinstance(statement, ast.Name) and isinstance(statement.ctx, ast.Store):
                self.shadowed_names.add(statement.id)
        self.nodes = []
        self.edges = []
        self.next_id = 0
        self.effect_ids = []

    def _module(self, suffix):
        return suffix if self.module_id == 'solve' else self.module_id + '__' + suffix

    def _node(self, op, params=None, source_node=None):
        node_id = '%s_%d' % (op, self.next_id)
        self.next_id += 1
        node = {'id': node_id, 'op': op}
        if params:
            node['params'] = params
        if source_node is not None:
            node['sourceSpan'] = self._span(source_node)
        self.nodes.append(node)
        return node_id

    def _edge(self, source, target, pin):
        self.edges.append({'from': source + '.value', 'to': target + '.' + pin})

    @staticmethod
    def _line(node):
        return '第 %s 行：' % getattr(node, 'lineno', '?')
    def _span(self, node):
        start_column = len(self.source_lines[node.lineno - 1].encode('utf-8')[:node.col_offset].decode('utf-8'))
        end_column = len(self.source_lines[node.end_lineno - 1].encode('utf-8')[:node.end_col_offset].decode('utf-8'))
        return {'startLine': node.lineno, 'startColumn': start_column,
                'endLine': node.end_lineno, 'endColumn': end_column}

    def _has_eager_effect(self, expressions):
        return any(isinstance(child, ast.Call) and isinstance(child.func, ast.Name) and
                   (child.func.id in self.registry or child.func.id in AGENT_CALLS or child.func.id in ('read', 'write') and
                    (hasattr(child, 'resource_encoding') or child.func.id not in self.shadowed_names and child.func.id not in self.constants))
                   for expression in expressions for child in ast.walk(expression))

    def _expression(self, node, inputs):
        if isinstance(node, ast.Name):
            if node.id in inputs:
                return inputs[node.id]
            if node.id in self.constants and node.id not in self.shadowed_names:
                value_id = self._node('const', {'value': self.constants[node.id],
                                                 'globalName': node.id}, node)
                self.nodes[-1]['label'] = node.id
                return value_id
            raise ValueError(self._line(node) + '变量 %s 尚未赋值' % node.id)
        if isinstance(node, ast.Constant) and type(node.value) in (int, float, str, bool, type(None)):
            if isinstance(node.value, int) and not -(1 << 63) <= node.value < (1 << 63):
                raise ValueError(self._line(node) + '整数超出沙盒支持范围')
            if isinstance(node.value, float) and not math.isfinite(node.value):
                raise ValueError(self._line(node) + '数字必须是有限值')
            return self._node('const', {'value': node.value}, node)
        if (isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.USub)
                and isinstance(node.operand, ast.Constant)
                and type(node.operand.value) in (int, float)):
            value = -node.operand.value
            if isinstance(value, int) and not -(1 << 63) <= value < (1 << 63):
                raise ValueError(self._line(node) + '整数超出沙盒支持范围')
            if isinstance(value, float) and not math.isfinite(value):
                raise ValueError(self._line(node) + '数字必须是有限值')
            return self._node('const', {'value': value}, node)
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.USub, ast.Not)):
            value = self._expression(node.operand, inputs)
            result = self._node('neg' if isinstance(node.op, ast.USub) else 'not', source_node=node)
            self._edge(value, result, 'value')
            return result
        if isinstance(node, ast.BinOp):
            operators = {ast.Add: 'add', ast.Sub: 'sub', ast.Mult: 'mul',
                         ast.Div: 'div', ast.FloorDiv: 'floordiv', ast.Mod: 'mod', ast.Pow: 'pow'}
            op = operators.get(type(node.op))
            if op is None:
                raise ValueError(self._line(node) + '不支持此二元运算')
            left = self._expression(node.left, inputs)
            right = self._expression(node.right, inputs)
            result = self._node(op, source_node=node)
            self._edge(left, result, 'a')
            self._edge(right, result, 'b')
            return result
        if isinstance(node, ast.Compare) and len(node.ops) > 1:
            return lower_chained_comparison(self, node, inputs)
        if isinstance(node, ast.Compare) and len(node.ops) == 1:
            operators = {ast.Eq: 'eq', ast.NotEq: 'ne', ast.Lt: 'lt',
                         ast.LtE: 'le', ast.Gt: 'gt', ast.GtE: 'ge'}
            op = operators.get(type(node.ops[0]))
            if op is None:
                raise ValueError(self._line(node) + '不支持此比较运算')
            left = self._expression(node.left, inputs)
            right = self._expression(node.comparators[0], inputs)
            result = self._node(op, source_node=node)
            self._edge(left, result, 'a')
            self._edge(right, result, 'b')
            return result
        if isinstance(node, ast.BoolOp) and isinstance(node.op, (ast.And, ast.Or)):
            if self._has_eager_effect(node.values):
                raise ValueError(self._line(node) + '短路表达式中的函数调用或文件读写尚不支持')
            result = self._expression(node.values[0], inputs)
            for value in node.values[1:]:
                right = self._expression(value, inputs)
                combined = self._node('and' if isinstance(node.op, ast.And) else 'or', source_node=node)
                self._edge(result, combined, 'a')
                self._edge(right, combined, 'b')
                result = combined
            return result
        if isinstance(node, ast.IfExp):
            if self._has_eager_effect((node.body, node.orelse)):
                raise ValueError(self._line(node) + '条件表达式分支中的函数调用或文件读写尚不支持')
            condition = self._expression(node.test, inputs)
            selected = self._expression(node.body, inputs)
            alternative = self._expression(node.orelse, inputs)
            result = self._node('select', source_node=node)
            self._edge(condition, result, 'condition')
            self._edge(selected, result, 'then')
            self._edge(alternative, result, 'else')
            return result
        if isinstance(node, ast.List):
            fields = ['item_%d' % index for index in range(len(node.elts))]
            result = self._node('list', {'fields': fields}, node)
            for field, item in zip(fields, node.elts):
                self._edge(self._expression(item, inputs), result, field)
            return result
        if (isinstance(node, ast.Subscript) and isinstance(node.slice, ast.Constant)
                and type(node.slice.value) in (int, str)):
            value = self._expression(node.value, inputs)
            result = self._node('get', {'key': node.slice.value}, node)
            self._edge(value, result, 'value')
            return result
        if isinstance(node, ast.Dict) and all(isinstance(key, ast.Constant) and type(key.value) is str
                                               for key in node.keys):
            fields = ['item_%d' % index for index in range(len(node.keys))]
            result = self._node('object', {'fields': fields,
                                           'keys': [key.value for key in node.keys]}, node)
            for field, value in zip(fields, node.values):
                self._edge(self._expression(value, inputs), result, field)
            return result
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in self.registry \
                and not hasattr(node, 'resource_encoding'):
            if node.func.id in self.shadowed_names:
                raise ValueError(self._line(node) + '调用目标被局部变量覆盖')
            definition = self.registry[node.func.id]
            if node.keywords or len(node.args) != len(definition['inputs']):
                raise ValueError(self._line(node) + '自定义函数调用参数数量不匹配')
            arguments = [self._expression(arg, inputs) for arg in node.args]
            result = self._node('call', source_node=node)
            self.nodes[-1]['module'] = definition['module']
            self.nodes[-1]['label'] = definition.get('label', node.func.id)
            for name, argument in zip(definition['inputs'], arguments):
                self._edge(argument, result, name)
            self.effect_ids.append(result)
            return result
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) \
                and node.func.id in ('read', 'write') and (hasattr(node, 'resource_encoding') or
                    node.func.id not in self.shadowed_names and node.func.id not in self.constants):
            expected = 1 if node.func.id == 'read' else 2
            if len(node.args) != expected or node.keywords:
                raise ValueError(self._line(node) + node.func.id + ' 调用参数数量不匹配')
            operation = node.func.id
            path = self._expression(node.args[0], inputs)
            params = {'operation': operation, 'encoding': getattr(node, 'resource_encoding', 'utf-8'),
                      'nativeOpen': hasattr(node, 'resource_encoding')}
            result = self._node('file', params, node)
            self._edge(path, result, 'path')
            if operation == 'write':
                self._edge(self._expression(node.args[1], inputs), result, 'content')
            self.effect_ids.append(result)
            return result
        if (isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
                and node.func.id in ('abs', 'len', 'sum', 'min', 'max', 'range')
                and node.func.id not in self.shadowed_names and node.func.id not in self.constants
                and len(node.args) == 1 and not node.keywords):
            value = self._expression(node.args[0], inputs)
            result = self._node('builtin', {'name': node.func.id}, node)
            self._edge(value, result, 'value')
            return result
        return lower_expression(self, node, inputs)

    def _source_line(self, statement):
        if hasattr(statement, '_visual_line'):
            return statement._visual_line
        return ast.get_source_segment(self.source, statement) or ast.unparse(statement)

    def _example_inputs(self):
        examples = {name: 41 for name in self.input_names}
        for node in ast.walk(self.function):
            if isinstance(node, ast.Subscript) and isinstance(node.value, ast.Name) \
                    and node.value.id in examples and isinstance(node.slice, ast.Constant):
                name, key = node.value.id, node.slice.value
                if type(key) is str:
                    value = examples[name] if isinstance(examples[name], dict) else {}
                    value[key] = 0
                    examples[name] = value
                elif type(key) is int and 0 <= key < 16:
                    examples[name] = [1] * max(key + 1,
                        len(examples[name]) if isinstance(examples[name], list) else 0)
            iteration = node.iter if isinstance(node, ast.For) else \
                node.generators[0].iter if isinstance(node, (ast.GeneratorExp, ast.ListComp, ast.DictComp)) else None
            if isinstance(iteration, ast.Name) and iteration.id in examples and examples[iteration.id] == 41:
                examples[iteration.id] = [1, 2, 3]
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) \
                    and node.func.id in ('sum', 'min', 'max', 'len') and len(node.args) == 1 \
                    and isinstance(node.args[0], ast.Name) and node.args[0].id in examples \
                    and examples[node.args[0].id] == 41:
                examples[node.args[0].id] = [1, 2, 3]
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) \
                    and node.func.id == 'read' and node.args \
                    and isinstance(node.args[0], ast.Name) and node.args[0].id in examples \
                    and examples[node.args[0].id] == 41:
                examples[node.args[0].id] = '任务.md'
        return 41 if len(self.input_names) == 1 and examples[self.input_names[0]] == 41 \
            else examples[self.input_names[0]] if len(self.input_names) == 1 \
            else examples

    def _names(self, expression):
        return expression_names(self, expression)

    def _build_expression_module(self, module_id, expression, input_names, statement):
        self.nodes = []
        self.edges = []
        self.next_id = 0
        self.effect_ids = []
        inputs = {name: self._node('input', {'name': name}) for name in input_names}
        result = self._expression(expression, inputs)
        output = self._node('return', source_node=expression)
        self.nodes[-1]['label'] = statement
        self._edge(result, output, 'value')
        for source, target in zip(self.effect_ids, self.effect_ids[1:] + [output]):
            self.edges.append({'from': source + '.next', 'to': target + '.exec'})
        positions, camera_size = self._pipeline_layout(self.nodes, self.edges)
        module = {
            'kind': 'expression',
            'label': '表达式',
            'inputs': input_names,
            'entry': self.effect_ids[0] if self.effect_ids else output,
            'nodes': self.nodes,
            'edges': self.edges,
        }
        layout = {'positions': positions, 'cameraSize': camera_size}
        return module, layout

    def _build_return_node(self, statement, module_id, node_id, locals_to_nodes, modules, layouts):
        if not isinstance(statement, ast.Return) or statement.value is None:
            raise ValueError(self._line(statement) + 'return 必须返回一个表达式')
        line = self._source_line(statement)
        input_names = self._names(statement.value)
        for name in input_names:
            if name not in locals_to_nodes:
                raise ValueError(self._line(statement) + '变量 %s 尚未赋值' % name)
        outer_nodes, outer_edges, outer_next_id = self.nodes, self.edges, self.next_id
        modules[module_id], layouts[module_id] = self._build_expression_module(module_id, statement.value, input_names, line)
        if hasattr(statement.value, 'resource_encoding'):
            modules[module_id]['scopeKind'] = 'resource'
        self.nodes, self.edges, self.next_id = outer_nodes, outer_edges, outer_next_id
        self.nodes.append({'id': node_id, 'op': 'return', 'module': module_id,
                           'label': line, 'sourceText': line, 'sourceSpan': self._span(statement)})
        for name in input_names:
            self._edge(locals_to_nodes[name], node_id, name)
        return node_id

    def _build_assignment_node(self, statement, module_id, node_id, locals_to_nodes, modules, layouts, symbols):
        mutation_key = None
        inplace_op = None
        if isinstance(statement, ast.AugAssign):
            inplace_op = {ast.Add: 'add', ast.Sub: 'sub', ast.Mult: 'mul', ast.Div: 'div',
                          ast.FloorDiv: 'floordiv', ast.Mod: 'mod', ast.Pow: 'pow'}.get(type(statement.op))
            if inplace_op is None:
                raise ValueError(self._line(statement) + '不支持此复合赋值运算')
        target = statement.targets[0] if isinstance(statement, ast.Assign) and len(statement.targets) == 1 \
            else statement.target if isinstance(statement, ast.AugAssign) else None
        if isinstance(target, ast.Subscript):
            if not isinstance(target.value, ast.Name) or not isinstance(target.slice, ast.Constant) \
                    or type(target.slice.value) not in (int, str):
                raise ValueError(self._line(statement) + '容器更新只支持变量上的整数或字符串常量键')
            target_name = target.value.id
            if target_name not in locals_to_nodes:
                raise ValueError(self._line(statement) + '变量 %s 尚未赋值' % target_name)
            mutation_key = target.slice.value
            expression = statement.value
        elif isinstance(statement, ast.Assign) and len(statement.targets) == 1 \
                and isinstance(target, ast.Name):
            target_name = target.id
            expression = statement.value
        elif isinstance(statement, ast.AugAssign) and isinstance(target, ast.Name):
            target_name = target.id
            if target_name not in locals_to_nodes:
                raise ValueError(self._line(statement) + '变量 %s 尚未赋值' % target_name)
            expression = statement.value
        else:
            raise ValueError(self._line(statement) + '当前只支持单变量赋值')
        line = self._source_line(statement)
        input_names = self._names(expression)
        for name in input_names:
            if name not in locals_to_nodes:
                raise ValueError(self._line(statement) + '变量 %s 尚未赋值' % name)
        outer_nodes, outer_edges, outer_next_id = self.nodes, self.edges, self.next_id
        modules[module_id], layouts[module_id] = self._build_expression_module(
            module_id, expression, input_names, line)
        self.nodes, self.edges, self.next_id = outer_nodes, outer_edges, outer_next_id
        params = {'key': mutation_key, 'target': target_name} if mutation_key is not None \
            else {'kind': 'assign', 'target': target_name}
        if inplace_op is not None:
            params['inplaceOp'] = inplace_op
        self.nodes.append({'id': node_id, 'op': 'setitem' if mutation_key is not None else 'statement',
                           'module': module_id, 'params': params,
                           'label': line, 'sourceText': line, 'sourceSpan': self._span(statement)})
        for name in input_names:
            self._edge(locals_to_nodes[name], node_id, name)
        if mutation_key is not None or inplace_op is not None:
            self._edge(locals_to_nodes[target_name], node_id, '@target')
        locals_to_nodes[target_name] = node_id
        symbols.append({'name': target_name, 'kind': 'local', 'definition': node_id})
        return node_id

    def _with_read_return(self, statement):
        if len(statement.items) != 1 or len(statement.body) != 1 \
                or not isinstance(statement.body[0], ast.Return) or statement.body[0].value is None:
            raise ValueError(self._line(statement) + 'with open 目前只支持单资源和一条 return')
        item = statement.items[0]
        opened, alias = item.context_expr, item.optional_vars
        if 'open' in self.shadowed_names or 'open' in self.constants or 'open' in self.registry \
                or not isinstance(opened, ast.Call) \
                or not isinstance(opened.func, ast.Name) or opened.func.id != 'open' \
                or not isinstance(alias, ast.Name):
            raise ValueError(self._line(statement) + 'with 只支持未被函数、常量或局部变量覆盖的 open(path)')
        encodings = [kw.value for kw in opened.keywords if kw.arg == 'encoding']
        if not 1 <= len(opened.args) <= 2 or len(encodings) != len(opened.keywords) or len(encodings) > 1:
            raise ValueError(self._line(opened) + 'open 只支持 path 和可选的文本读取模式')
        mode = 'r'
        if len(opened.args) == 2:
            if not isinstance(opened.args[1], ast.Constant) or type(opened.args[1].value) is not str:
                raise ValueError(self._line(opened) + 'open 模式必须是字符串常量')
            mode = opened.args[1].value
        if mode not in ('r', 'rt'):
            raise ValueError(self._line(opened) + '沙盒文件只支持文本读取模式')
        encoding = None
        if encodings:
            value = encodings[0]
            if not isinstance(value, ast.Constant) or value.value is not None and \
                    (type(value.value) is not str or value.value.lower() not in ('utf-8', 'utf8')):
                raise ValueError(self._line(opened) + 'open 只支持默认编码或 UTF-8')
            encoding = 'utf-8' if value.value is not None else None
        returned = statement.body[0].value
        if not isinstance(returned, ast.Call) or not isinstance(returned.func, ast.Attribute) \
                or not isinstance(returned.func.value, ast.Name) \
                or returned.func.value.id != alias.id or returned.func.attr != 'read' \
                or returned.args or returned.keywords:
            raise ValueError(self._line(statement.body[0]) + 'with open 内只支持返回文件的 read()')
        read_call = ast.Call(func=ast.Name(id='read', ctx=ast.Load()), args=[opened.args[0]], keywords=[])
        read_call.resource_encoding = encoding
        ast.copy_location(read_call, returned)
        converted = ast.Return(value=read_call)
        ast.copy_location(converted, statement)
        ast.fix_missing_locations(converted)
        return converted

    def build(self):
        body = self.function.body
        if body and isinstance(body[0], ast.Expr) and isinstance(body[0].value, ast.Constant) \
                and isinstance(body[0].value.value, str):
            body = body[1:]
        if not body:
            raise ValueError(self._line(self.function) + '函数体不能为空')
        final_return = self._with_read_return(body[-1]) if isinstance(body[-1], ast.With) else \
            body[-1] if isinstance(body[-1], ast.Return) else None
        final_try = body[-1] if isinstance(body[-1], ast.Try) else None
        valid_final_try = final_try is not None and len(final_try.handlers) == 1 \
            and not final_try.orelse and not final_try.finalbody \
            and len(final_try.body) == 1 and isinstance(final_try.body[0], ast.Return) \
            and len(final_try.handlers[0].body) == 1 \
            and isinstance(final_try.handlers[0].body[0], ast.Return)
        if final_return is None and not (isinstance(body[-1], ast.If) and body[-1].orelse) \
                and not valid_final_try:
            raise ValueError(self._line(self.function) + '函数必须以 return 或完整 if/else 返回结束')
        statements = body[:-1] if final_return is not None else body

        modules = {}
        layouts = {}
        self.nodes = []
        self.edges = []
        self.next_id = 0
        input_ids = {name: self._node('input', {'name': name}) for name in self.input_names}
        outer_nodes, outer_edges, outer_next_id = self.nodes, self.edges, self.next_id
        locals_to_nodes = input_ids.copy()
        statement_ids = []
        branch_returns = {}
        loop_positions = {}
        previous_exit = ''
        symbols = [{'name': name, 'kind': 'parameter'} for name in self.input_names]
        for index, statement in enumerate(statements, start=1):
            if isinstance(statement, (ast.While, ast.For)):
                if statement.orelse or not statement.body:
                    raise ValueError(self._line(statement) + '循环暂不支持 else 或空循环体')
                for_target = ''
                if isinstance(statement, ast.For):
                    if not isinstance(statement.target, ast.Name):
                        raise ValueError(self._line(statement) + 'for 目标必须是单个变量')
                    for_target = statement.target.id
                    if for_target in locals_to_nodes:
                        raise ValueError(self._line(statement) + '暂不支持复用已有变量作为 for 目标')
                updated_names = set()
                for body_statement in statement.body:
                    if isinstance(body_statement, ast.Assign) and len(body_statement.targets) == 1 \
                            and isinstance(body_statement.targets[0], ast.Name):
                        target = body_statement.targets[0].id
                    elif isinstance(body_statement, ast.AugAssign) and isinstance(body_statement.target, ast.Name):
                        target = body_statement.target.id
                    else:
                        raise ValueError(self._line(body_statement) + '循环体暂只支持单变量赋值')
                    if target not in locals_to_nodes or target == for_target:
                        raise ValueError(self._line(body_statement) + '循环体只能更新循环前已定义的变量')
                    updated_names.add(target)
                phi_ids = {}
                for offset, name in enumerate(sorted(updated_names)):
                    phi_id = 'phi_%d_%d' % (index, offset)
                    self.nodes.append({'id': phi_id, 'op': 'phi', 'params': {'name': name},
                                       'label': name, 'sourceSpan': self._span(statement)})
                    self._edge(locals_to_nodes[name], phi_id, 'initial')
                    locals_to_nodes[name] = phi_id
                    phi_ids[name] = phi_id
                    loop_positions[phi_id] = [index * 2.0 - 1.5, 0.0, -2.25 - offset * 1.5]
                expression = statement.iter if isinstance(statement, ast.For) else statement.test
                module_id = self._module(('expression_for_%d' if for_target else 'expression_while_%d') % index)
                source_line = ('for ' + for_target + ' in ' if for_target else 'while ') \
                    + self._source_line(expression) + ':'
                input_names = self._names(expression)
                for name in input_names:
                    if name not in locals_to_nodes:
                        raise ValueError(self._line(statement) + '变量 %s 尚未赋值' % name)
                modules[module_id], layouts[module_id] = self._build_expression_module(
                    module_id, expression, input_names, source_line)
                self.nodes, self.edges, self.next_id = outer_nodes, outer_edges, outer_next_id
                loop_id = 'loop_%d' % index
                loop_node = {'id': loop_id, 'op': 'for' if for_target else 'branch',
                             'module': module_id, 'label': source_line,
                             'sourceText': source_line, 'sourceSpan': self._span(statement)}
                if not for_target:
                    loop_node['visualKind'] = 'while'
                self.nodes.append(loop_node)
                statement_ids.append(loop_id)
                for name in input_names:
                    self._edge(locals_to_nodes[name], loop_id, name)
                if previous_exit:
                    self.edges.append({'from': previous_exit, 'to': loop_id + '.exec'})
                body_env = locals_to_nodes.copy()
                if for_target:
                    body_env[for_target] = loop_id
                body_exit = loop_id + ('.each' if for_target else '.then')
                for body_index, body_statement in enumerate(statement.body, start=1):
                    body_id = 'loop_%d_statement_%d' % (index, body_index)
                    body_module = self._module('expression_loop_%d_%d' % (index, body_index))
                    self._build_assignment_node(body_statement, body_module, body_id,
                                                body_env, modules, layouts, symbols)
                    self.edges.append({'from': body_exit, 'to': body_id + '.exec'})
                    body_exit = body_id + '.next'
                    loop_positions[body_id] = [index * 2.0 + 1.5, 0.0, 2.25 + body_index * 1.75]
                self.edges.append({'from': body_exit, 'to': loop_id + '.exec'})
                for name, phi_id in phi_ids.items():
                    self._edge(body_env[name], phi_id, 'updated')
                previous_exit = loop_id + ('.done' if for_target else '.else')
                continue
            if isinstance(statement, ast.Expr):
                module_id = self._module('expression_statement_%d' % index)
                input_names = self._names(statement.value)
                for name in input_names:
                    if name not in locals_to_nodes:
                        raise ValueError(self._line(statement) + '变量 %s 尚未赋值' % name)
                modules[module_id], layouts[module_id] = self._build_expression_module(
                    module_id, statement.value, input_names, self._source_line(statement))
                self.nodes, self.edges, self.next_id = outer_nodes, outer_edges, outer_next_id
                statement_id = 'statement_%d' % index
                self.nodes.append({'id': statement_id, 'op': 'statement', 'module': module_id,
                                   'params': {'kind': 'effect'}, 'label': self._source_line(statement),
                                   'sourceText': self._source_line(statement),
                                   'sourceSpan': self._span(statement)})
                statement_ids.append(statement_id)
                for name in input_names:
                    self._edge(locals_to_nodes[name], statement_id, name)
                if previous_exit:
                    self.edges.append({'from': previous_exit, 'to': statement_id + '.exec'})
                previous_exit = statement_id + '.next'
                continue
            if isinstance(statement, ast.Try):
                if len(statement.handlers) != 1 or statement.orelse or statement.finalbody \
                        or len(statement.body) != 1 or not isinstance(statement.body[0], ast.Return) \
                        or len(statement.handlers[0].body) != 1 \
                        or not isinstance(statement.handlers[0].body[0], ast.Return):
                    raise ValueError(self._line(statement) + 'try 目前只支持一个 except 分支，且两侧各返回一条语句')
                handler = statement.handlers[0]
                if not isinstance(handler.type, ast.Name) or handler.type.id != 'ZeroDivisionError' \
                        or handler.name or handler.type.id in self.constants.keys() | self.registry.keys() | self.shadowed_names:
                    raise ValueError(self._line(handler) + '当前只支持未被同名变量覆盖且不带别名的 except ZeroDivisionError')
                try_expression = statement.body[0].value
                if try_expression is None:
                    raise ValueError(self._line(statement.body[0]) + 'return 必须返回一个表达式')
                try_module = self._module('expression_try_%d' % index)
                try_inputs = self._names(try_expression)
                for name in try_inputs:
                    if name not in locals_to_nodes:
                        raise ValueError(self._line(try_expression) + '变量 %s 尚未赋值' % name)
                modules[try_module], layouts[try_module] = self._build_expression_module(
                    try_module, try_expression, try_inputs, self._source_line(statement.body[0]))
                self.nodes, self.edges, self.next_id = outer_nodes, outer_edges, outer_next_id
                try_id = 'try_%d' % index
                self.nodes.append({'id': try_id, 'op': 'trycall', 'module': try_module,
                                   'params': {'exceptions': ['ZeroDivisionError']},
                                   'label': 'try', 'sourceText': self._source_line(statement),
                                   'sourceSpan': self._span(statement)})
                statement_ids.append(try_id)
                for name in try_inputs:
                    self._edge(locals_to_nodes[name], try_id, name)
                if previous_exit:
                    self.edges.append({'from': previous_exit, 'to': try_id + '.exec'})
                result_id = self._node('get', {'key': 'result'}, statement.body[0])
                ok_id = self._node('get', {'key': 'ok'}, statement)
                self._edge(try_id, result_id, 'value')
                self._edge(try_id, ok_id, 'value')
                branch_id = 'try_branch_%d' % index
                self.nodes.append({'id': branch_id, 'op': 'branch', 'label': 'except?',
                                   'sourceSpan': self._span(handler)})
                statement_ids.append(branch_id)
                self._edge(ok_id, branch_id, 'condition')
                self.edges.append({'from': try_id + '.next', 'to': branch_id + '.exec'})
                success_id = 'return_try_%d_success' % index
                self.nodes.append({'id': success_id, 'op': 'return',
                                   'label': self._source_line(statement.body[0]),
                                   'sourceText': self._source_line(statement.body[0]),
                                   'sourceSpan': self._span(statement.body[0])})
                self.edges.append({'from': result_id + '.value', 'to': success_id + '.value'})
                self.edges.append({'from': branch_id + '.then', 'to': success_id + '.exec'})
                except_id = self._build_return_node(handler.body[0],
                    self._module('expression_try_%d_except' % index),
                    'return_try_%d_except' % index, locals_to_nodes, modules, layouts)
                self.edges.append({'from': branch_id + '.else', 'to': except_id + '.exec'})
                branch_returns[success_id] = [index * 2.0 + 1.5, 0.0, -1.75]
                branch_returns[except_id] = [index * 2.0 + 1.5, 0.0, 1.75]
                previous_exit = ''
                continue
            if isinstance(statement, ast.If):
                if (len(statement.body) != 1 or not isinstance(statement.body[0], ast.Return)
                        or (statement.orelse and (len(statement.orelse) != 1
                                                  or not isinstance(statement.orelse[0], ast.Return)))):
                    raise ValueError(self._line(statement) + '当前 if 分支只支持单条 return')
                module_id = self._module('expression_if_%d' % index)
                branch_id = 'branch_%d' % index
                condition_line = 'if ' + self._source_line(statement.test) + ':'
                input_names = self._names(statement.test)
                for name in input_names:
                    if name not in locals_to_nodes:
                        raise ValueError(self._line(statement) + '变量 %s 尚未赋值' % name)
                modules[module_id], layouts[module_id] = self._build_expression_module(
                    module_id, statement.test, input_names, condition_line)
                self.nodes, self.edges, self.next_id = outer_nodes, outer_edges, outer_next_id
                self.nodes.append({'id': branch_id, 'op': 'branch', 'module': module_id,
                                   'label': condition_line, 'sourceText': condition_line,
                                   'sourceSpan': self._span(statement)})
                statement_ids.append(branch_id)
                for name in input_names:
                    self._edge(locals_to_nodes[name], branch_id, name)
                if previous_exit:
                    self.edges.append({'from': previous_exit, 'to': branch_id + '.exec'})
                then_id = self._build_return_node(statement.body[0],
                    self._module('expression_if_%d_then' % index), 'return_if_%d_then' % index,
                    locals_to_nodes, modules, layouts)
                self.edges.append({'from': branch_id + '.then', 'to': then_id + '.exec'})
                branch_returns[then_id] = [index * 2.0 + 1.5, 0.0, -1.75]
                if statement.orelse:
                    else_id = self._build_return_node(statement.orelse[0],
                        self._module('expression_if_%d_else' % index), 'return_if_%d_else' % index,
                        locals_to_nodes, modules, layouts)
                    self.edges.append({'from': branch_id + '.else', 'to': else_id + '.exec'})
                    branch_returns[else_id] = [index * 2.0 + 1.5, 0.0, 1.75]
                    previous_exit = ''
                else:
                    previous_exit = branch_id + '.else'
                continue
            if not isinstance(statement, (ast.Assign, ast.AugAssign)):
                raise ValueError(self._line(statement) + '当前只支持赋值、循环、if 返回和末尾 return')
            module_id = self._module('expression_%d' % index)
            statement_id = 'statement_%d' % index
            self._build_assignment_node(statement, module_id, statement_id,
                                        locals_to_nodes, modules, layouts, symbols)
            statement_ids.append(statement_id)
            if previous_exit:
                self.edges.append({'from': previous_exit, 'to': statement_id + '.exec'})
            previous_exit = statement_id + '.next'

        output_id = ''
        if final_return is not None:
            output_id = self._build_return_node(final_return, self._module('expression_return'),
                'return_statement', locals_to_nodes, modules, layouts)
            if previous_exit:
                self.edges.append({'from': previous_exit, 'to': output_id + '.exec'})

        entry = statement_ids[0] if statement_ids else output_id
        positions = {node_id: [0.0, 0.0, (index - (len(input_ids) - 1) / 2) * 1.25]
                     for index, node_id in enumerate(input_ids.values())}
        for index, node_id in enumerate(statement_ids, start=1):
            positions[node_id] = [index * 2.0, 0.0, 0.0]
        positions.update(branch_returns)
        positions.update(loop_positions)
        if output_id:
            positions[output_id] = [(len(statement_ids) + 1) * 2.0, 0.0, 0.0]
        camera_size = max(9.0, 8.0 + len(statement_ids) * 0.5)
        modules[self.module_id] = {
            'kind': 'function',
            'language': 'python',
            'label': getattr(self.function, '_lab_visual_name', self.function.name),
            'inputs': self.input_names,
            'scope': {'symbols': symbols},
            'entry': entry,
            'nodes': self.nodes,
            'edges': self.edges,
        }
        layouts[self.module_id] = {'positions': positions, 'cameraSize': camera_size}
        class_visual = getattr(self.function, '_lab_machine_visual', None)
        if class_visual is not None:
            layouts[self.module_id]['classVisual'] = class_visual
        return {
            'formatVersion': 'module/1',
            'entry': self.module_id,
            'exampleTask': self._example_inputs(),
            'modules': modules,
            'machineLayout': layouts,
        }

    @staticmethod
    def _pipeline_layout(nodes, edges):
        by_id = {node['id']: node for node in nodes}
        incoming, consumers = {}, {}
        for edge in edges:
            source = edge['from'].rsplit('.', 1)[0]
            target = edge['to'].rsplit('.', 1)[0]
            incoming.setdefault(target, []).append(source)
            consumers.setdefault(source, []).append(target)
        ranks = {}
        def rank(node_id):
            if node_id in ranks:
                return ranks[node_id]
            node = by_id[node_id]
            sources = incoming.get(node_id, [])
            if node['op'] not in ('input', 'const'):
                ranks[node_id] = max((rank(source) for source in sources), default=-1) + 1
            else:
                ranks[node_id] = 0
            return ranks[node_id]

        for node_id in by_id:
            rank(node_id)
        columns = dict(ranks)
        # Pull shorter branches toward their consumer so side-fed constants sit
        # beside the operator that uses them, rather than at the start of the line.
        for node_id in sorted(by_id, key=lambda item: (ranks[item], item), reverse=True):
            targets = consumers.get(node_id, [])
            if not targets or by_id[node_id]['op'] == 'return':
                continue
            input_floor = max((columns[source] + 1 for source in incoming.get(node_id, [])), default=0)
            consumer_ceiling = min(columns[target] - 1 for target in targets)
            columns[node_id] = max(input_floor, consumer_ceiling)
        positions = {}
        for column in sorted(set(columns.values())):
            members = sorted(node_id for node_id in by_id if columns[node_id] == column)
            mainline = [node_id for node_id in members if by_id[node_id]['op'] != 'const']
            feeders = [node_id for node_id in members if by_id[node_id]['op'] == 'const']
            for index, node_id in enumerate(mainline):
                z = (index - (len(mainline) - 1) / 2) * 1.25
                positions[node_id] = [column * 1.75, 0.0, z]
            for index, node_id in enumerate(feeders):
                positions[node_id] = [column * 1.75, 0.0, 1.25 + index * 1.0]
        max_column = max(columns.values(), default=0)
        camera_size = min(25.0, max(9.0, 8.0 + max_column * 0.5))
        return positions, camera_size

def import_source(source):
    try:
        tree = ast.parse(source)
    except SyntaxError as exc:
        raise ValueError('第 %s 行 Python 语法错误：%s' % (exc.lineno, exc.msg)) from exc
    top_level = tree.body
    if top_level and isinstance(top_level[0], ast.Expr) and isinstance(top_level[0].value, ast.Constant) \
            and isinstance(top_level[0].value.value, str):
        top_level = top_level[1:]
    top_level = lower_classes(top_level)
    functions = []
    constants = {}
    for node in top_level:
        if isinstance(node, ast.FunctionDef):
            functions.append(node)
            continue
        if not isinstance(node, ast.Assign) or len(node.targets) != 1 \
                or not isinstance(node.targets[0], ast.Name):
            raise ValueError(PythonSubset._line(node) + '模块顶层只支持函数定义和标量常量赋值')
        try:
            value = ast.literal_eval(node.value)
        except (ValueError, TypeError, SyntaxError, MemoryError, RecursionError) as exc:
            raise ValueError(PythonSubset._line(node) + '模块级变量必须是字面量标量常量') from exc
        if type(value) not in (int, float, str, bool, type(None)):
            raise ValueError(PythonSubset._line(node) + '模块级常量只支持数字、字符串、布尔值或 None')
        if type(value) is int and not -(1 << 63) <= value < (1 << 63):
            raise ValueError(PythonSubset._line(node) + '整数超出沙盒支持范围')
        if isinstance(value, float) and not math.isfinite(value):
            raise ValueError(PythonSubset._line(node) + '数字必须是有限值')
        constants[node.targets[0].id] = value
    user_functions = [function for function in functions if not getattr(function, '_lab_generated', False)]
    if not user_functions:
        raise ValueError('Python 文件至少需要一个顶层函数')
    function_names = {node.name for node in functions}
    if len(function_names) != len(functions):
        raise ValueError('顶层函数名称不能重复')
    if function_names.intersection(constants):
        raise ValueError('顶层函数名称不能与模块常量重名')
    user_modules = {f.name: 'solve' if len(user_functions) == 1 else 'fn_%d' % i
                    for i, f in enumerate(user_functions)}
    registry = {f.name: {'module': getattr(f, '_lab_module_id', user_modules.get(f.name)),
                         'inputs': [arg.arg for arg in f.args.args],
                         'label': getattr(f, '_lab_visual_name', f.name)} for f in functions}
    entry_name = 'main' if 'main' in user_modules else 'solve' if 'solve' in user_modules else user_functions[0].name
    modules, layouts = {}, {}
    example_task = None
    for function in functions:
        part = PythonSubset(source, function, registry, registry[function.name]['module'], constants).build()
        modules.update(part['modules'])
        layouts.update(part['machineLayout'])
        if function.name == entry_name:
            example_task = part['exampleTask']
    return {'formatVersion': 'module/1', 'entry': registry[entry_name]['module'],
            'exampleTask': example_task, 'modules': modules, 'machineLayout': layouts}

def post_source(source, filename, endpoint):
    base = endpoint.rstrip('/')
    with urllib.request.urlopen(base + '/program', timeout=3) as response:
        current = json.load(response)
    request = urllib.request.Request(
        base + '/import',
        data=json.dumps({'source': source, 'filename': filename, 'revision': current['revision']}).encode('utf-8'),
        headers={'Content-Type': 'application/json'},
        method='POST',
    )
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        return json.load(exc)

def main():
    if len(sys.argv) not in (2, 3):
        raise SystemExit('用法: python import_python.py <source.py> [http://127.0.0.1:7332]')
    source_path = Path(sys.argv[1]).resolve()
    endpoint = sys.argv[2] if len(sys.argv) == 3 else 'http://127.0.0.1:7332'
    if source_path.suffix.lower() != '.py':
        raise ValueError('请选择 .py 文件')
    source = source_path.read_text(encoding='utf-8-sig')
    result = post_source(source, source_path.name, endpoint)
    if not result.get('ok'):
        raise RuntimeError(json.dumps(result, ensure_ascii=False))
    print(json.dumps({'ok': True, 'entry': result['entry'], 'revision': result['revision']}, ensure_ascii=False))

if __name__ == '__main__':
    main()
