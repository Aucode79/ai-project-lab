"""Lower a restricted, lazy Python generator expression into graph nodes."""
import ast


def lower_generator_expression(subset, node, inputs):
    lazy = isinstance(node, ast.GeneratorExp)
    dictionary = isinstance(node, ast.DictComp)
    noun = '生成器' if lazy else '字典推导式' if dictionary else '列表推导式'
    final = subset.function.body[-1] if subset.function.body else None
    if lazy and (not isinstance(final, ast.Return) or final.value is not node):
        raise ValueError(subset._line(node) + '生成器表达式目前只支持直接作为函数最终返回值')
    if len(node.generators) != 1 or node.generators[0].is_async \
            or not isinstance(node.generators[0].target, ast.Name):
        raise ValueError(subset._line(node) + noun + '目前只支持一个同步循环和单变量目标')
    generator = node.generators[0]
    elements = [node.key, node.value] if dictionary else [node.elt]
    expressions = [generator.iter] + elements + generator.ifs
    if any(isinstance(child, (ast.GeneratorExp, ast.ListComp, ast.DictComp)) for expression in expressions
           for child in ast.walk(expression)):
        raise ValueError(subset._line(node) + ('暂不支持嵌套生成器表达式' if lazy else '暂不支持嵌套推导式'))
    if subset._has_eager_effect(elements + generator.ifs):
        raise ValueError(subset._line(node) + noun + '过滤和产出表达式不支持副作用调用')
    items = subset._expression(generator.iter, inputs)
    target = generator.target.id
    body_inputs = inputs.copy()
    item_node = subset._node('generator_input', {'name': target}, generator.target)
    body_inputs[target] = item_node
    element_nodes = [subset._expression(element, body_inputs) for element in elements]
    filters = [subset._expression(condition, body_inputs) for condition in generator.ifs]
    element_fields = ['key', 'value'] if dictionary else ['element']
    fields = ['items'] + element_fields + ['filter_%d' % index for index in range(len(filters))]
    op = 'generator' if lazy else 'dictcomp' if dictionary else 'listcomp'
    result = subset._node(op, {'target': target, 'itemNode': item_node,
                                        'fields': fields,
                                        'filterCount': len(filters),
                                        'visualExtent': [2.0, 0.75, 1.5]}, node)
    subset._edge(items, result, 'items')
    for field, element in zip(element_fields, element_nodes):
        subset._edge(element, result, field)
    for index, filter_node in enumerate(filters):
        subset._edge(filter_node, result, 'filter_%d' % index)
    return result
