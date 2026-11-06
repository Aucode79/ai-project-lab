"""Lower Python expressions that need runtime-specific graph structure."""
import ast

from generator_expression_lowering import lower_generator_expression

AGENT_CALLS = {'model', 'dispatch', 'message'}


def lower_chained_comparison(subset, node, inputs):
    if subset._has_eager_effect([node.left] + node.comparators):
        raise ValueError(subset._line(node) + '链式比较中的函数调用或文件读写尚不支持')
    operators = {ast.Eq: 'eq', ast.NotEq: 'ne', ast.Lt: 'lt',
                 ast.LtE: 'le', ast.Gt: 'gt', ast.GtE: 'ge'}
    previous = node.left
    result = ''
    for operator, operand in zip(node.ops, node.comparators):
        op = operators.get(type(operator))
        if op is None:
            raise ValueError(subset._line(node) + '不支持此比较运算')
        left = subset._expression(previous, inputs)
        right = subset._expression(operand, inputs)
        comparison = subset._node(op, source_node=node)
        subset._edge(left, comparison, 'a')
        subset._edge(right, comparison, 'b')
        if result:
            combined = subset._node('and', source_node=node)
            subset._edge(result, combined, 'a')
            subset._edge(comparison, combined, 'b')
            result = combined
        else:
            result = comparison
        previous = operand
    return result


def lower_f_string(subset, node, inputs):
    result = None
    for part in node.values:
        if isinstance(part, ast.Constant) and isinstance(part.value, str):
            value_id = subset._node('const', {'value': part.value}, part)
        elif isinstance(part, ast.FormattedValue):
            if subset._has_eager_effect([part.value]):
                raise ValueError(subset._line(part) + '格式化字符串中的函数调用或文件读写尚不支持')
            if part.conversion not in (-1, ord('s'), ord('r'), ord('a')):
                raise ValueError(subset._line(part) + '格式化字符串转换类型不受支持')
            spec = ''
            if part.format_spec is not None:
                if not all(isinstance(item, ast.Constant) and isinstance(item.value, str)
                           for item in part.format_spec.values):
                    raise ValueError(subset._line(part) + '格式说明只支持字符串常量')
                spec = ''.join(item.value for item in part.format_spec.values)
            expression = subset._expression(part.value, inputs)
            value_id = subset._node('format', {'conversion': part.conversion, 'formatSpec': spec}, part)
            subset._edge(expression, value_id, 'value')
        else:
            raise ValueError(subset._line(part) + '格式化字符串包含不支持的内容')
        if result is None:
            result = value_id
        else:
            combined = subset._node('add', source_node=part)
            subset._edge(result, combined, 'a')
            subset._edge(value_id, combined, 'b')
            result = combined
    return result if result is not None else subset._node('const', {'value': ''}, node)


def lower_expression(subset, node, inputs):
    if isinstance(node, (ast.GeneratorExp, ast.ListComp, ast.DictComp)):
        return lower_generator_expression(subset, node, inputs)
    if isinstance(node, ast.JoinedStr):
        return lower_f_string(subset, node, inputs)
    if not isinstance(node, ast.Call) or not isinstance(node.func, ast.Name) \
            or node.func.id not in AGENT_CALLS:
        raise ValueError(subset._line(node) + '不支持此表达式：' + ast.dump(node, include_attributes=False))
    name = node.func.id
    if name in subset.shadowed_names or name in subset.constants:
        raise ValueError(subset._line(node) + 'Agent 调用名称被局部变量或模块常量覆盖')
    if node.keywords:
        raise ValueError(subset._line(node) + name + ' 不支持关键字参数')
    if name == 'message':
        if len(node.args) != 2 or not isinstance(node.args[0], ast.Constant) \
                or not isinstance(node.args[0].value, str):
            raise ValueError(subset._line(node) + 'message(role, value) 的 role 必须是字符串常量')
        op, params, arguments = name, {'role': node.args[0].value}, [('value', node.args[1])]
    else:
        if len(node.args) != 2:
            raise ValueError(subset._line(node) + name + ' 需要两个位置参数')
        ports = ('messages', 'tools') if name == 'model' else ('action', 'tools')
        op, params, arguments = name, None, list(zip(ports, node.args))
    values = [(pin, subset._expression(argument, inputs)) for pin, argument in arguments]
    result = subset._node(op, params, node)
    for pin, value in values:
        subset._edge(value, result, pin)
    subset.effect_ids.append(result)
    return result
