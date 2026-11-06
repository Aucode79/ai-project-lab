class Counter:
    def __init__(self):
        self.n = 0

    def inc(self):
        self.n += 1


def main():
    first = Counter()
    alias = first
    alias.inc()
    other = Counter()
    first.inc()
    return [first.n, alias.n, other.n]
