"""Visual module program -> executable Python. No agent policy lives here."""
import copy
import hashlib
import json
import re
import sys

PURE = {'input', 'const', 'tool', 'tools', 'get', 'eq', 'lt', 'gt', 'le', 'ge', 'ne',
        'add', 'sub', 'mul', 'div', 'floordiv', 'mod', 'pow', 'neg', 'not',
        'and', 'or', 'select', 'builtin', 'format', 'list', 'listcomp', 'dictcomp', 'object', 'phi', 'generator', 'generator_input'}
BUILTINS = {'abs', 'len', 'sum', 'min', 'max', 'range'}
INPLACE = {'add': 'iadd', 'sub': 'isub', 'mul': 'imul', 'div': 'itruediv',
           'floordiv': 'ifloordiv', 'mod': 'imod', 'pow': 'ipow'}
EXCEPTIONS = {'ZeroDivisionError': 'ZeroDivisionError'}
PORTS = {
    'input': [], 'const': [], 'tool': [], 'tools': [], 'generator': [], 'listcomp': [], 'dictcomp': [], 'generator_input': [],
    'get': ['value'], 'eq': ['a', 'b'], 'lt': ['a', 'b'], 'gt': ['a', 'b'],
    'le': ['a', 'b'], 'ge': ['a', 'b'], 'ne': ['a', 'b'],
    'add': ['a', 'b'], 'sub': ['a', 'b'], 'mul': ['a', 'b'],
    'div': ['a', 'b'], 'floordiv': ['a', 'b'], 'mod': ['a', 'b'], 'pow': ['a', 'b'],
    'and': ['a', 'b'], 'or': ['a', 'b'], 'select': ['condition', 'then', 'else'],
    'neg': ['value'], 'not': ['value'], 'builtin': ['value'], 'format': ['value'],
    'list': [], 'object': [], 'phi': ['initial', 'updated'],
    'call': [], 'trycall': [], 'for': ['items'], 'setitem': ['@target'], 'file': ['path'],
    'model': ['messages', 'tools'], 'dispatch': ['action', 'tools'],
    'append': ['items', 'value'], 'message': ['value'], 'branch': ['condition'],
    'statement': [], 'return': ['value'], 'raise': ['value'], 'nop': [],
}
TOOLS = {
    'world.snapshot': {}, 'world.inspect': {'id': 'string'},
    'world.move': {'node': 'string'}, 'world.pickup': {'crate': 'string'},
    'world.drop': {}, 'fs.list': {'path': 'string'}, 'fs.read': {'path': 'string'},
    'fs.write': {'path': 'string', 'content': 'string'},
    'fs.rename': {'path': 'string', 'target': 'string'}, 'fs.delete': {'path': 'string'},
}


def ports(node, definitions):
    op = node['op']
    if op == 'file':
        inputs = ['path'] + (['content'] if node.get('params', {}).get('operation') == 'write' else [])
    elif op in ('call', 'trycall', 'statement', 'setitem') or (op in ('return', 'branch', 'for') and node.get('module')):
        inputs = definitions.get(node.get('module'), {}).get('inputs', [])
        if op == 'setitem' or (op == 'statement' and node.get('params', {}).get('inplaceOp')):
            inputs = inputs + ['@target']
    elif op in ('tools', 'list', 'object', 'generator', 'listcomp', 'dictcomp'):
        inputs = node.get('params', {}).get('fields', [])
    else:
        inputs = PORTS.get(op, [])
    control = ([] if op in PURE or op in ('return', 'raise') else
               ['then', 'else'] if op == 'branch' else
               ['each', 'done'] if op == 'for' else ['next'])
    return {'inputs': inputs, 'outputs': ['value'], 'control': control, 'effect': op not in PURE}


def semantic(program):
    p = copy.deepcopy(program)
    p.pop('layout', None)
    p.pop('machineLayout', None)
    p.pop('exampleTask', None)
    for module in p.get('modules', {}).values():
        module.pop('label', None)
        module.pop('scopeKind', None)
        for node in module.get('nodes', []):
            node.pop('label', None)
            node.pop('position', None)
            node.pop('sourceText', None)
            node.pop('sourceSpan', None)
            node.pop('visualKind', None)
            node.get('params', {}).pop('literalType', None)
        module['nodes'] = sorted(module.get('nodes', []), key=lambda n: n['id'])
        module['edges'] = sorted(module.get('edges', []), key=lambda e: (e['from'], e['to']))
    return p


def compile_program(program):
    errors = []
    def error(mid, nid, message):
        errors.append({'code': 'INVALID_MODULE', 'moduleId': mid, 'entity_id': nid, 'message': message})
    if program.get('formatVersion') != 'module/1':
        return {'ok': False, 'errors': [{'message': 'Expected module/1'}], 'python': ''}
    definitions = program.get('modules', {})
    if program.get('entry') not in definitions:
        error('', '', '入口模块不存在')
    for mid, module in definitions.items():
        if not re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*', mid):
            error(mid, '', '模块 ID 必须是标识符')
        nodes = {n['id']: n for n in module.get('nodes', [])}
        if len(nodes) != len(module.get('nodes', [])):
            error(mid, '', '节点 ID 重复')
        if module.get('entry') not in nodes or nodes.get(module.get('entry'), {}).get('op') in PURE:
            error(mid, '', '模块入口必须指向可执行节点')
        if len(set(module.get('inputs', []))) != len(module.get('inputs', [])):
            error(mid, '', '模块输入名重复')
        incoming, outgoing = {}, {}
        for edge in module.get('edges', []):
            try:
                a, ap = edge['from'].rsplit('.', 1)
                b, bp = edge['to'].rsplit('.', 1)
                na, nb = nodes[a], nodes[b]
                pa, pb = ports(na, definitions), ports(nb, definitions)
                is_control = ap in pa['control'] and bp == 'exec' and pb['effect']
                is_data = ap == 'value' and bp in pb['inputs']
                if not (is_control or is_data):
                    raise ValueError('端口不存在或控制/数据类型不匹配')
                if is_data:
                    if edge['to'] in incoming:
                        raise ValueError('数据输入只接受一条连线')
                    incoming[edge['to']] = a
                else:
                    if edge['from'] in outgoing:
                        raise ValueError('控制出口只接受一条连线')
                    outgoing[edge['from']] = b
            except (KeyError, ValueError) as exc:
                error(mid, '', '无效连接 %s: %s' % (edge, exc))
        for nid, n in nodes.items():
            if not re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*', nid) or n.get('op') not in PORTS:
                error(mid, nid, '节点 ID 或操作无效')
                continue
            spec = ports(n, definitions)
            if n['op'] in ('call', 'trycall', 'statement', 'setitem') and n.get('module') not in definitions:
                error(mid, nid, '引用的模块不存在')
            if n['op'] == 'setitem' and type(n.get('params', {}).get('key')) not in (int, str):
                error(mid, nid, 'setitem 需要整数或字符串键')
            if n['op'] in ('generator', 'listcomp', 'dictcomp'):
                params = n.get('params', {})
                count = params.get('filterCount', -1)
                element_fields = ['key', 'value'] if n['op'] == 'dictcomp' else ['element']
                fields = ['items'] + element_fields + ['filter_%d' % i for i in range(count)] \
                    if type(count) is int and 0 <= count <= 100 else []
                if not re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*', str(params.get('target', ''))) \
                        or params.get('fields') != fields or not fields:
                    error(mid, nid, n['op'] + ' 需要有效目标、过滤数量和输入端口')
                item_node = nodes.get(params.get('itemNode', ''), {})
                if params.get('itemNode') and (item_node.get('op') != 'generator_input' or
                        item_node.get('params', {}).get('name') != params.get('target')):
                    error(mid, nid, n['op'] + ' 的迭代输入节点必须对应目标变量')
            if n['op'] == 'generator_input' and not re.fullmatch(
                    r'[A-Za-z_][A-Za-z_0-9]*', str(n.get('params', {}).get('name', ''))):
                error(mid, nid, 'generator_input 需要有效变量名')
            if n['op'] == 'trycall' and any(name not in EXCEPTIONS for name in n.get('params', {}).get('exceptions', [])):
                error(mid, nid, 'trycall 包含不支持的异常类型')
            if n['op'] == 'file' and n.get('params', {}).get('operation') not in ('read', 'write'):
                error(mid, nid, 'file 节点只支持 read 或 write')
            if n['op'] in ('statement', 'setitem') and n.get('params', {}).get('inplaceOp') \
                    and n['params']['inplaceOp'] not in INPLACE:
                error(mid, nid, '不支持此复合赋值运算')
            if n['op'] == 'branch' and n.get('module') and n['module'] not in definitions:
                error(mid, nid, '条件模块不存在')
            if n['op'] == 'for' and n.get('module') and n['module'] not in definitions:
                error(mid, nid, '迭代源模块不存在')
            if n['op'] == 'statement':
                params = n.get('params', {})
                if params.get('kind') != 'effect' and (params.get('kind') != 'assign' or not re.fullmatch(
                        r'[A-Za-z_][A-Za-z_0-9]*', str(params.get('target', '')))):
                    error(mid, nid, 'statement 需要有效的赋值目标')
            if n['op'] == 'input' and n.get('params', {}).get('name') not in module.get('inputs', []):
                error(mid, nid, '输入节点不属于模块接口')
            if n['op'] == 'return' and n.get('module') not in (None, '') and n.get('module') not in definitions:
                error(mid, nid, 'return 引用的表达式模块不存在')
            if n['op'] == 'tool' and n.get('params', {}).get('name') not in TOOLS:
                error(mid, nid, '未知工具绑定')
            if n['op'] == 'builtin' and n.get('params', {}).get('name') not in BUILTINS:
                error(mid, nid, '未知内置函数')
            if n['op'] == 'format':
                params = n.get('params', {})
                if type(params.get('conversion')) is not int or params['conversion'] not in (-1, 115, 114, 97) \
                        or not isinstance(params.get('formatSpec'), str):
                    error(mid, nid, 'format 需要受支持的转换和静态格式说明')
            if n['op'] == 'object':
                fields = n.get('params', {}).get('fields', [])
                keys = n.get('params', {}).get('keys', fields)
                if len(fields) != len(keys):
                    error(mid, nid, '字典键与输入端口数量不一致')
            for pin in spec['inputs']:
                if nid + '.' + pin not in incoming and pin not in n.get('params', {}).get('defaults', {}) and n['op'] != 'tools':
                    error(mid, nid, '必需输入未连接：' + pin)
            if n['op'] == 'phi':
                update_source = incoming.get(nid + '.updated')
                if update_source in nodes and nodes[update_source]['op'] in PURE:
                    error(mid, nid, '状态回边必须来自执行节点')
            for pin in spec['control']:
                if nid + '.' + pin not in outgoing:
                    error(mid, nid, '控制出口未连接：' + pin)
        # Only pure-expression cycles are invalid. Module call cycles are ordinary recursion.
        def visit(nid, stack):
            if nid in stack:
                raise ValueError('纯数据表达式成环')
            if nodes[nid]['op'] not in PURE:
                return
            for pin in ports(nodes[nid], definitions)['inputs']:
                source = incoming.get(nid + '.' + pin)
                if source in nodes:
                    visit(source, stack | {nid})
        try:
            for nid in nodes:
                visit(nid, set())
        except ValueError as exc:
            error(mid, '', str(exc))
        # Duplicate tool names on the same collection are ambiguous.
        for n in nodes.values():
            if n.get('op') == 'tools':
                names = [nodes[s].get('params', {}).get('name') for pin in ports(n, definitions)['inputs']
                         if (s := incoming.get(n['id'] + '.' + pin)) and nodes[s]['op'] == 'tool']
                if len(names) != len(set(names)):
                    error(mid, n['id'], '工具集合内名称重复')
    if errors:
        return {'ok': False, 'errors': errors, 'python': '', 'warnings': []}
    p = semantic(program)
    digest = hashlib.sha256(json.dumps(p, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
    lines = ['# Generated from module/1; edit the visual program, not this file.',
             'import operator', '']
    mapping = {}
    def emit(s):
        lines.append(s)
    for mid in sorted(definitions):
        module = definitions[mid]
        nodes = {n['id']: n for n in module['nodes']}
        edges = {e['to']: e['from'].rsplit('.', 1)[0] for e in module['edges'] if not e['to'].endswith('.exec')}
        control = {e['from']: e['to'].rsplit('.', 1)[0] for e in module['edges'] if e['to'].endswith('.exec')}
        def arg(n, pin, bindings=None):
            source = edges.get(n['id'] + '.' + pin)
            return expr(source, bindings) if source else repr(n.get('params', {}).get('defaults', {}).get(pin))
        def expr(nid, bindings=None):
            n = nodes[nid]
            op, q = n['op'], n.get('params', {})
            bindings = bindings or {}
            if op not in PURE:
                return 'v[%r]' % nid
            if op == 'input':
                return bindings.get(q['name'], 'arguments[%r]' % q['name'])
            if op == 'generator_input':
                return bindings[q['name']]
            if op == 'const':
                return repr(q.get('value'))
            if op == 'tool':
                return repr(q['name'])
            if op in ('list', 'tools'):
                xs = [arg(n, f, bindings) for f in ports(n, definitions)['inputs']
                      if op != 'tools' or n['id'] + '.' + f in edges]
                return '[' + ', '.join(xs) + ']'
            if op == 'object':
                fields = ports(n, definitions)['inputs']
                keys = q.get('keys', fields)
                return '{' + ', '.join(repr(key) + ': ' + arg(n, field, bindings)
                                       for field, key in zip(fields, keys)) + '}'
            if op == 'get':
                return '(%s)[%r]' % (arg(n, 'value', bindings), q.get('key'))
            if op == 'not':
                return '(not %s)' % arg(n, 'value', bindings)
            if op == 'neg':
                return '(-%s)' % arg(n, 'value', bindings)
            if op == 'builtin':
                return '%s(%s)' % (q['name'], arg(n, 'value', bindings))
            if op == 'format':
                value = arg(n, 'value', bindings)
                conversion = q['conversion']
                if conversion == 115: value = 'str(%s)' % value
                elif conversion == 114: value = 'repr(%s)' % value
                elif conversion == 97: value = 'ascii(%s)' % value
                return 'format(%s, %r)' % (value, q['formatSpec'])
            if op == 'select':
                return '(%s if %s else %s)' % (arg(n, 'then', bindings), arg(n, 'condition', bindings), arg(n, 'else', bindings))
            if op in ('generator', 'listcomp', 'dictcomp'):
                scope = dict(bindings)
                target = '_gen_' + nid
                scope[q['target']] = target
                filters = []
                for i in range(q['filterCount']):
                    filter_id = edges[nid + '.filter_%d' % i]
                    filters.append('(%r, lambda %s: %s)' % (filter_id, target, expr(filter_id, scope)))
                item_id = q.get('itemNode') or next((candidate['id'] for candidate in nodes.values()
                    if candidate['op'] == 'generator_input' and candidate.get('params', {}).get('name') == q['target']), '')
                if op == 'dictcomp':
                    key_id, value_id = edges[nid + '.key'], edges[nid + '.value']
                    element_id = ''
                    element = 'lambda %s: (%s, %s)' % (target, expr(key_id, scope), expr(value_id, scope))
                else:
                    element_id = edges[nid + '.element']
                    element = 'lambda %s: %s' % (target, expr(element_id, scope))
                items = arg(n, 'items', bindings)
                if op in ('listcomp', 'dictcomp'): items = 'iter(%s)' % items
                generated = 'rt.lazy_generator(%r, %r, call_id, %s, %r, [%s], %r, %s)' % (
                    mid, nid, items, item_id, ', '.join(filters), element_id, element)
                if op == 'listcomp': return 'list(%s)' % generated
                return 'dict(%s)' % generated if op == 'dictcomp' else generated
            if op == 'phi':
                updated = edges[nid + '.updated']
                return '(v[%r] if %r in v else %s)' % (updated, updated, arg(n, 'initial', bindings))
            return '(%s %s %s)' % (arg(n, 'a', bindings),
                {'eq': '==', 'lt': '<', 'gt': '>', 'le': '<=', 'ge': '>=', 'ne': '!=',
                 'add': '+', 'sub': '-', 'mul': '*', 'div': '/', 'floordiv': '//',
                 'mod': '%', 'pow': '**', 'and': 'and', 'or': 'or'}[op], arg(n, 'b', bindings))
        emit('def module_%s(rt, **arguments):' % mid)
        emit('    call_id = rt.enter(%r, arguments)' % mid)
        emit('    v = {}')
        emit('    iterators = {}')
        emit('    iterator_args = {}')
        emit('    pc = %r' % module['entry'])
        emit('    try:')
        emit('        while pc is not None:')
        emit('            rt.check_cancel()')
        for nid in sorted(nodes):
            n = nodes[nid]
            op, q = n['op'], n.get('params', {})
            if op in PURE:
                continue
            start = len(lines) + 1
            emit('            if pc == %r:' % nid)
            # Trace actual inputs, not speculative values from unexecuted branches.
            ins = ', '.join(repr(pin) + ': ' + arg(n, pin) for pin in ports(n, definitions)['inputs'])
            if op == 'for':
                emit('                if %r not in iterator_args:' % nid)
                emit('                    iterator_args[%r] = {' % nid + ins + '}')
                emit('                args = iterator_args[%r]' % nid)
            else:
                emit('                args = {' + ins + '}')
            emit('                rt.node(call_id, %r, %r, args)' % (mid, nid))
            if op == 'branch':
                if n.get('module'):
                    emit('                v[%r] = bool(module_%s(rt, **args))' % (nid, n['module']))
                else:
                    emit('                v[%r] = bool(args["condition"])' % nid)
                emit('                pc = %r if v[%r] else %r' % (control[nid + '.then'], nid, control[nid + '.else']))
            elif op == 'for':
                if n.get('module'):
                    emit('                if %r not in iterators:' % nid)
                    emit('                    iterators[%r] = iter(module_%s(rt, **args))' % (nid, n['module']))
                else:
                    emit('                if %r not in iterators:' % nid)
                    emit('                    iterators[%r] = iter(args["items"])' % nid)
                emit('                try:')
                emit('                    v[%r] = next(iterators[%r])' % (nid, nid))
                emit('                    pc = %r' % control[nid + '.each'])
                emit('                except StopIteration:')
                emit('                    del iterators[%r]' % nid)
                emit('                    del iterator_args[%r]' % nid)
                emit('                    pc = %r' % control[nid + '.done'])
            elif op == 'return':
                if n.get('module'):
                    emit('                value = module_%s(rt, **args)' % n['module'])
                    emit('                rt.value(call_id, %r, %r, value)' % (mid, nid))
                    emit('                return value')
                else:
                    emit('                rt.value(call_id, %r, %r, args["value"])' % (mid, nid))
                    emit('                return args["value"]')
            elif op == 'raise':
                emit('                raise RuntimeError(args["value"])')
            else:
                target = 'v[%r]' % nid
                if op == 'statement':
                    if q.get('inplaceOp'):
                        inputs = definitions[n['module']].get('inputs', [])
                        passed = '{' + ', '.join('%r: args[%r]' % (name, name) for name in inputs) + '}'
                        emit('                value = module_%s(rt, **%s)' % (n['module'], passed))
                        emit('                %s = operator.%s(args["@target"], value)' %
                             (target, INPLACE[q['inplaceOp']]))
                    else:
                        emit('                %s = module_%s(rt, **args)' % (target, n['module']))
                elif op == 'setitem':
                    inputs = definitions[n['module']].get('inputs', [])
                    passed = '{' + ', '.join('%r: args[%r]' % (name, name) for name in inputs) + '}'
                    emit('                value = module_%s(rt, **%s)' % (n['module'], passed))
                    if q.get('inplaceOp'):
                        emit('                value = operator.%s(args["@target"][%r], value)' %
                             (INPLACE[q['inplaceOp']], q['key']))
                    emit('                args["@target"][%r] = value' % q['key'])
                    emit('                %s = args["@target"]' % target)
                elif op == 'file':
                    operation = q['operation']
                    emit('                %s = rt.file_io(%r, args, %r, %r)' %
                         (target, operation, q.get('encoding', 'utf-8'), q.get('nativeOpen', False)))
                elif op == 'call':
                    emit('                %s = module_%s(rt, **args)' % (target, n['module']))
                elif op == 'trycall':
                    emit('                try:')
                    emit('                    %s = {"ok": True, "result": module_%s(rt, **args)}' % (target, n['module']))
                    emit('                except Exception as exc:')
                    if q.get('exceptions'):
                        caught = ', '.join(EXCEPTIONS[name] for name in q['exceptions'])
                        exception_tuple = '(' + caught + (',' if len(q['exceptions']) == 1 else '') + ')'
                        emit('                    if isinstance(exc, %s):' % exception_tuple)
                        emit('                        %s = {"ok": False, "error": str(exc)}' % target)
                        emit('                    else:')
                        emit('                        raise')
                    else:
                        emit('                    %s = {"ok": False, "error": str(exc)}' % target)
                elif op == 'append':
                    emit('                args["items"].append(args["value"])')
                    emit('                %s = args["items"]' % target)
                elif op == 'message':
                    emit('                %s = rt.message(%r, args["value"])' % (target, q.get('role', 'user')))
                elif op == 'model':
                    emit('                %s = rt.model(args["messages"], args["tools"])' % target)
                elif op == 'dispatch':
                    emit('                %s = rt.dispatch(args["action"], args["tools"])' % target)
                else:
                    emit('                %s = None' % target)
                emit('                pc = %r' % control[nid + '.next'])
            emit('                rt.value(call_id, %r, %r, v.get(%r))' % (mid, nid, nid))
            emit('                continue')
            mapping[mid + '/' + nid] = {'start': start, 'end': len(lines)}
        emit('            raise RuntimeError("Unknown control target: " + str(pc))')
        emit('    finally:')
        emit('        rt.leave(call_id)')
        emit('')
    emit('def run(rt, **arguments):')
    emit('    return module_%s(rt, **arguments)' % program['entry'])
    code = '\n'.join(lines) + '\n'
    compile(code, '<visual-program>', 'exec')
    return {'ok': True, 'python': code, 'ir_hash': digest, 'sourceMap': mapping, 'errors': [], 'warnings': []}


if __name__ == '__main__':
    try:
        source = json.load(open(sys.argv[1], encoding='utf-8')) if len(sys.argv) > 1 else json.load(sys.stdin)
        print(json.dumps(compile_program(source), ensure_ascii=True))
    except Exception as exc:
        print(json.dumps({'ok': False, 'python': '', 'errors': [{'message': str(exc)}]}, ensure_ascii=True))
