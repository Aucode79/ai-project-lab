"""Lower a small, explicit Python class subset into ordinary function ASTs."""
import ast
import copy


CONTROL_FLOW = (ast.If, ast.For, ast.AsyncFor, ast.While, ast.With, ast.AsyncWith,
                ast.Try, getattr(ast, 'TryStar', ast.Try), ast.Match)


def _line(node):
    return '第 %s 行：' % getattr(node, 'lineno', '?')


class _InstanceSyntaxRewriter(ast.NodeTransformer):
    def __init__(self, classes, current_class=None, receiver=''):
        self.classes = classes
        self.current_class = current_class
        self.receiver = receiver
        self.variable_types = {receiver: current_class} if receiver and current_class else {}
        self.allowed_instance_names = set()
        self.allowed_constructor_calls = 0

    def _class_for(self, expression):
        if isinstance(expression, ast.Name):
            if expression.id == self.receiver:
                return self.current_class
            return self.variable_types.get(expression.id)
        return None

    def visit_Attribute(self, node):
        class_name = self._class_for(node.value)
        if class_name is None:
            return self.generic_visit(node)
        definition = self.classes[class_name]
        if node.attr in definition['methods']:
            raise ValueError(_line(node) + '实例方法必须通过调用执行')
        if node.attr not in definition['fields']:
            raise ValueError(_line(node) + '类 %s 没有字段 %s' % (class_name, node.attr))
        if isinstance(node.value, ast.Name):
            self.allowed_instance_names.add(node.value.id)
            value = self.visit(node.value)
            self.allowed_instance_names.remove(node.value.id)
        else:
            value = self.visit(node.value)
        result = ast.Subscript(value=value, slice=ast.Constant(node.attr), ctx=node.ctx)
        return ast.copy_location(result, node)

    def visit_Name(self, node):
        if isinstance(node.ctx, ast.Load) and self._class_for(node) is not None \
                and node.id not in self.allowed_instance_names:
            raise ValueError(_line(node) + '实例值目前只能用于属性访问、方法调用或变量别名')
        return node

    def visit_Assign(self, node):
        value = node.value
        if isinstance(value, ast.Call) and isinstance(value.func, ast.Name) \
                and value.func.id in self.classes and len(node.targets) == 1 \
                and isinstance(node.targets[0], ast.Name):
            self.allowed_constructor_calls += 1
            result = self.generic_visit(node)
            self.allowed_constructor_calls -= 1
            return result
        if isinstance(value, ast.Name) and self._class_for(value) is not None \
                and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            self.allowed_instance_names.add(value.id)
            result = self.generic_visit(node)
            self.allowed_instance_names.remove(value.id)
            return result
        return self.generic_visit(node)

    def visit_Call(self, node):
        if isinstance(node.func, ast.Name) and node.func.id in self.classes \
                and not self.allowed_constructor_calls:
            raise ValueError(_line(node) + '构造出的实例必须先赋给局部变量')
        if isinstance(node.func, ast.Attribute):
            class_name = self._class_for(node.func.value)
            if class_name is not None:
                definition = self.classes[class_name]
                method = definition['methods'].get(node.func.attr)
                if method is None:
                    raise ValueError(_line(node.func) + '类 %s 没有方法 %s' % (class_name, node.func.attr))
                receiver_name = node.func.value.id if isinstance(node.func.value, ast.Name) else ''
                if receiver_name:
                    self.allowed_instance_names.add(receiver_name)
                receiver = self.visit(node.func.value)
                if receiver_name:
                    self.allowed_instance_names.remove(receiver_name)
                result = ast.Call(
                    func=ast.Name(id=method['function'].name, ctx=ast.Load()),
                    args=[receiver] + [self.visit(argument) for argument in node.args],
                    keywords=[self.visit(keyword) for keyword in node.keywords],
                )
                return ast.copy_location(result, node)
        return self.generic_visit(node)

    def visit_function_body(self, function):
        rewritten = []
        for statement in function.body:
            if isinstance(statement, CONTROL_FLOW):
                rebound = sorted({node.id for node in ast.walk(statement)
                                  if isinstance(node, ast.Name)
                                  and isinstance(node.ctx, (ast.Store, ast.Del))
                                  and node.id in self.variable_types})
                if rebound:
                    raise ValueError(_line(statement) + '条件或循环中暂不支持重新赋值类实例变量：' +
                                     ', '.join(rebound))
            rewritten.append(self.visit(statement))
            if isinstance(statement, ast.Assign) and len(statement.targets) == 1 \
                    and isinstance(statement.targets[0], ast.Name):
                target = statement.targets[0].id
                value = statement.value
                inferred = None
                if isinstance(value, ast.Call) and isinstance(value.func, ast.Name) \
                        and value.func.id in self.classes:
                    inferred = value.func.id
                elif isinstance(value, ast.Name):
                    inferred = self.variable_types.get(value.id)
                if inferred:
                    self.variable_types[target] = inferred
                else:
                    self.variable_types.pop(target, None)
        function.body = rewritten
        return function


def _method_body(class_name, method_name, method, classes):
    if method.decorator_list:
        raise ValueError(_line(method) + '类方法暂不支持装饰器')
    if not method.args.args:
        raise ValueError(_line(method) + '实例方法必须声明接收实例的第一个参数')
    receiver = method.args.args[0].arg
    if any(isinstance(node, ast.Name) and node.id == receiver
           and isinstance(node.ctx, (ast.Store, ast.Del)) for node in ast.walk(method)):
        raise ValueError(_line(method) + '实例方法不能重新绑定接收实例的变量')
    rewriter = _InstanceSyntaxRewriter(classes, class_name, receiver)
    rewriter.visit_function_body(method)
    if method_name == '__init__' and any(
            isinstance(node, ast.Return) and node.value is not None
            and not (isinstance(node.value, ast.Constant) and node.value.value is None)
            for node in ast.walk(method)):
        raise ValueError(_line(method) + '__init__ 只能返回 None')
    last = method.body[-1] if method.body else method
    if not (isinstance(last, ast.Return)
            or isinstance(last, ast.If) and last.orelse):
        implicit = ast.Return(value=ast.Constant(value=None))
        ast.copy_location(implicit, last)
        implicit._visual_line = ''
        method.body.append(implicit)
    method._lab_generated = True
    method._lab_module_id = classes[class_name]['method_ids'][method_name]
    method._lab_visual_name = class_name + '.' + method_name
    method._lab_machine_visual = {'role': 'method', 'className': class_name,
                                  'fields': sorted(classes[class_name]['fields'])}
    ast.fix_missing_locations(method)
    return method


def _factory(class_node, class_name, definition):
    init = definition['methods'].get('__init__')
    if init is None:
        raise ValueError(_line(class_node) + '类目前必须定义 __init__')
    init_function = init['function']
    args = copy.deepcopy(init_function.args.args[1:])
    receiver = init_function.args.args[0].arg
    receiver_target = ast.Name(id=receiver, ctx=ast.Store())
    receiver_value = ast.Name(id=receiver, ctx=ast.Load())
    state = ast.Assign(targets=[receiver_target], value=ast.Dict(keys=[], values=[]))
    state._visual_line = ''
    init_call = ast.Expr(value=ast.Call(
        func=ast.Name(id=init_function.name, ctx=ast.Load()),
        args=[copy.deepcopy(receiver_value)] + [ast.Name(id=argument.arg, ctx=ast.Load()) for argument in args],
        keywords=[],
    ))
    init_call._visual_line = ''
    returned = ast.Return(value=copy.deepcopy(receiver_value))
    returned._visual_line = ''
    for node in (state, init_call, returned):
        ast.copy_location(node, class_node)
    factory = ast.FunctionDef(
        name=class_name,
        args=ast.arguments(posonlyargs=[], args=args, vararg=None, kwonlyargs=[], kw_defaults=[],
                           kwarg=None, defaults=[]),
        body=[state, init_call, returned], decorator_list=[],
    )
    ast.copy_location(factory, class_node)
    factory._lab_generated = True
    factory._lab_constructor = True
    factory._lab_module_id = definition['module_id']
    factory._lab_visual_name = class_name
    factory._lab_machine_visual = {'role': 'factory', 'className': class_name,
                                   'fields': sorted(definition['fields'])}
    return ast.fix_missing_locations(factory)


def lower_classes(body):
    class_nodes = [node for node in body if isinstance(node, ast.ClassDef)]
    if not class_nodes:
        return body
    occupied = {node.id for root in body for node in ast.walk(root) if isinstance(node, ast.Name)}
    occupied.update(node.arg for root in body for node in ast.walk(root) if isinstance(node, ast.arg))
    occupied.update(node.name for root in body for node in ast.walk(root)
                    if isinstance(node, (ast.FunctionDef, ast.ClassDef)))
    occupied.update(node.name for root in body for node in ast.walk(root)
                    if isinstance(node, ast.ExceptHandler) and node.name)
    for node in body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            occupied.add(node.targets[0].id)
    classes = {}
    for index, class_node in enumerate(class_nodes):
        if class_node.bases or class_node.decorator_list or class_node.keywords:
            raise ValueError(_line(class_node) + '类暂不支持继承、装饰器或关键字参数')
        members = class_node.body[1:] if class_node.body and isinstance(class_node.body[0], ast.Expr) \
            and isinstance(class_node.body[0].value, ast.Constant) \
            and isinstance(class_node.body[0].value.value, str) else class_node.body
        if not members or any(not isinstance(member, ast.FunctionDef) for member in members):
            raise ValueError(_line(class_node) + '类体目前只支持实例方法定义')
        special_methods = [member.name for member in members if member.name.startswith('__')
                           and member.name != '__init__']
        if special_methods:
            raise ValueError(_line(class_node) + '类暂不支持 Python 特殊方法或双下划线方法：' + ', '.join(special_methods))
        if len({member.name for member in members}) != len(members):
            raise ValueError(_line(class_node) + '类方法名称不能重复')
        prefix = '_lab_class_%d' % index
        method_ids = {}
        for method_index, method in enumerate(members):
            hidden_name = prefix + '_' + str(method_index)
            while hidden_name in occupied:
                hidden_name += '_'
            occupied.add(hidden_name)
            method_ids[method.name] = hidden_name
        method_functions = {}
        for method in members:
            hidden_name = method_ids[method.name]
            method.name = hidden_name
            method_functions[method.name] = method
        class_info = {'fields': set(), 'methods': {}, 'method_ids': method_ids,
                      'module_id': prefix + '_factory'}
        classes[class_node.name] = class_info
        for old_name, hidden_name in method_ids.items():
            method_functions[hidden_name]._lab_original_method_name = old_name
            class_info['methods'][old_name] = {'function': method_functions[hidden_name]}
        init = class_info['methods'].get('__init__')
        if init is None:
            raise ValueError(_line(class_node) + '类目前必须定义 __init__')
        init_function = init['function']
        init_receiver = init_function.args.args[0].arg if init_function.args.args else ''
        initialized = set()
        for statement in init_function.body:
            for node in ast.walk(statement):
                if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) \
                        and node.value.id == init_receiver and isinstance(node.ctx, ast.Load) \
                        and node.attr not in initialized:
                    raise ValueError(_line(node) + '实例字段必须先在 __init__ 中赋值')
            if isinstance(statement, ast.Assign) and len(statement.targets) == 1 \
                    and isinstance(statement.targets[0], ast.Attribute):
                target = statement.targets[0]
                if isinstance(target.value, ast.Name) and target.value.id == init_receiver:
                    initialized.add(target.attr)
        class_info['fields'] = initialized
        private_fields = sorted(name for name in initialized if name.startswith('__'))
        if private_fields:
            raise ValueError(_line(init_function) + '类暂不支持双下划线实例字段：' + ', '.join(private_fields))
        collisions = sorted(initialized.intersection(method_ids))
        if collisions:
            raise ValueError(_line(init_function) + '实例字段和方法不能同名：' + ', '.join(collisions))
        assigned_before_return = set()
        for index, statement in enumerate(init_function.body):
            returns = [node for node in ast.walk(statement) if isinstance(node, ast.Return)]
            if returns:
                if not isinstance(statement, ast.Return) or len(returns) != 1:
                    raise ValueError(_line(statement) + '__init__ 暂不支持条件或循环中的 return')
                if index != len(init_function.body) - 1:
                    raise ValueError(_line(statement) + '__init__ 的 return 必须是最后一条语句')
                if not initialized.issubset(assigned_before_return):
                    raise ValueError(_line(statement) + '__init__ 必须先初始化所有实例字段')
            if isinstance(statement, ast.Assign) and len(statement.targets) == 1 \
                    and isinstance(statement.targets[0], ast.Attribute):
                target = statement.targets[0]
                if isinstance(target.value, ast.Name) and target.value.id == init_receiver:
                    assigned_before_return.add(target.attr)
        for method in members:
            receiver = method.args.args[0].arg if method.args.args else ''
            for node in ast.walk(method):
                if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) \
                        and node.value.id == receiver and node.attr not in method_ids \
                        and node.attr not in initialized:
                    raise ValueError(_line(node) + '实例字段 %s 必须先在 __init__ 中赋值' % node.attr)
    lowered_classes = {}
    for class_node in class_nodes:
        definition = classes[class_node.name]
        methods = []
        for method in class_node.body:
            if isinstance(method, ast.FunctionDef):
                original_name = method._lab_original_method_name
                methods.append(_method_body(class_node.name, original_name, method, classes))
        factory = _factory(class_node, class_node.name, definition)
        lowered_classes[class_node.name] = [factory] + methods
    output = []
    for node in body:
        if isinstance(node, ast.ClassDef):
            output.extend(lowered_classes[node.name])
        elif isinstance(node, ast.FunctionDef):
            output.append(_InstanceSyntaxRewriter(classes).visit_function_body(node))
        else:
            output.append(node)
    return output
