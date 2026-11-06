def main(values):
    return {f"value-{value:02d}": value * 2 for value in values if value > 0}
