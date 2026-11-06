"""Resolve expression inputs while respecting generator-local names."""
import ast

from expression_lowering import AGENT_CALLS


def expression_names(subset, expression):
    names = set()

    class References(ast.NodeVisitor):
        def __init__(self):
            self.local_names = set()

        def visit_Name(self, node):
            if isinstance(node.ctx, ast.Load) and node.id not in self.local_names \
                    and (node.id not in subset.constants or node.id in subset.shadowed_names):
                names.add(node.id)

        def visit_Call(self, node):
            known = node.func.id in subset.registry or node.func.id in AGENT_CALLS or \
                node.func.id in ('abs', 'len', 'sum', 'min', 'max', 'range', 'read', 'write') \
                if isinstance(node.func, ast.Name) else False
            if not known or node.func.id in subset.shadowed_names:
                self.visit(node.func)
            for argument in node.args:
                self.visit(argument)
            for keyword in node.keywords:
                self.visit(keyword.value)

        def visit_GeneratorExp(self, node):
            self.visit_comprehension(node)

        def visit_ListComp(self, node):
            self.visit_comprehension(node)

        def visit_DictComp(self, node):
            self.visit_comprehension(node)

        def visit_comprehension(self, node):
            outer_names = self.local_names.copy()
            for generator in node.generators:
                self.visit(generator.iter)
                if isinstance(generator.target, ast.Name):
                    self.local_names.add(generator.target.id)
                for condition in generator.ifs:
                    self.visit(condition)
            if isinstance(node, ast.DictComp):
                self.visit(node.key)
                self.visit(node.value)
            else:
                self.visit(node.elt)
            self.local_names = outer_names

    References().visit(expression)
    return sorted(names)
