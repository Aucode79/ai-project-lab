"""Editable initial graph; the runtime never special-cases these modules."""
import json
from pathlib import Path


def node(id, op, label='', **kw):
    return dict(id=id, op=op, label=label or id, **kw)


def graph(inputs, entry, nodes, data, control):
    return {'inputs': inputs, 'entry': entry, 'nodes': nodes,
            'edges': [{'from': a, 'to': b} for a, b in data + control]}


def preset():
    n = node
    tools = ['world.snapshot', 'world.move', 'world.pickup', 'world.drop', 'fs.list', 'fs.read', 'fs.write']
    root = graph(['task'], 'start', [
        n('task', 'input', '对话输入', params={'name': 'task'}),
        *[n('t' + str(i), 'tool', t, params={'name': t}) for i, t in enumerate(tools)],
        n('tools', 'tools', '已连接的工具', params={'fields': ['t' + str(i) for i in range(len(tools))]}),
        n('start', 'call', 'Agent · 进入内部', module='agent'), n('done', 'return', '最终回答'),
    ], [('task.value', 'start.task'), ('tools.value', 'start.tools'), ('start.value', 'done.value')] +
       [('t%d.value' % i, 'tools.t%d' % i) for i in range(len(tools))], [('start.next', 'done.exec')])
    agent = graph(['task', 'tools'], 'init', [
        n('task', 'input', '任务', params={'name': 'task'}), n('tools', 'input', '工具集合', params={'name': 'tools'}),
        n('init', 'call', '初始化上下文', module='context'),
        n('model', 'call', '调用模型', module='model_request'),
        n('is_done', 'get', '读取工具名', params={'key': 'tool'}),
        n('finish', 'const', 'finish', params={'value': 'finish'}), n('equal', 'eq', '是否结束'),
        n('branch', 'branch', '结束或继续'),
        n('assistant', 'message', '模型消息', params={'role': 'assistant'}),
        n('remember', 'append', '记录模型调用'),
        n('execute', 'call', '分派工具', module='tool_dispatch'),
        n('observation', 'message', '工具返回消息', params={'role': 'user'}),
        n('feedback', 'append', '观测进入上下文'),
        n('done', 'return', '返回回答'),
    ], [('task.value', 'init.task'), ('init.value', 'model.messages'), ('tools.value', 'model.tools'),
        ('model.value', 'is_done.value'), ('is_done.value', 'equal.a'), ('finish.value', 'equal.b'),
        ('equal.value', 'branch.condition'), ('model.value', 'assistant.value'),
        ('init.value', 'remember.items'), ('assistant.value', 'remember.value'),
        ('model.value', 'execute.action'), ('tools.value', 'execute.tools'),
        ('execute.value', 'observation.value'), ('init.value', 'feedback.items'),
        ('observation.value', 'feedback.value'), ('model.value', 'done.value')],
       [('init.next', 'model.exec'), ('model.next', 'branch.exec'), ('branch.then', 'done.exec'),
        ('branch.else', 'assistant.exec'), ('assistant.next', 'remember.exec'), ('remember.next', 'execute.exec'),
        ('execute.next', 'observation.exec'), ('observation.next', 'feedback.exec'), ('feedback.next', 'model.exec')])
    context = graph(['task'], 'message', [n('task', 'input', '任务', params={'name': 'task'}),
        n('message', 'message', '用户消息', params={'role': 'user'}),
        n('messages', 'list', '初始消息列表', params={'fields': ['user']}), n('done', 'return', '上下文')],
        [('task.value', 'message.value'), ('message.value', 'messages.user'), ('messages.value', 'done.value')],
        [('message.next', 'done.exec')])
    def wrapper(mid, op, inputs):
        return graph(inputs, 'invoke', [*[n(k, 'input', k, params={'name': k}) for k in inputs],
            n('invoke', op, mid), n('done', 'return', '返回值')],
            [(k + '.value', 'invoke.' + k) for k in inputs] + [('invoke.value', 'done.value')], [('invoke.next', 'done.exec')])
    return {'formatVersion': 'module/1', 'entry': 'main', 'modules': {'main': root, 'agent': agent,
        'context': context, 'model_request': wrapper('模型 API', 'model', ['messages', 'tools']),
        'tool_dispatch': wrapper('CLI 工具分派', 'dispatch', ['action', 'tools'])}, 'layout': {}}


if __name__ == '__main__':
    import sys
    Path(sys.argv[1]).write_text(json.dumps(preset(), ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
