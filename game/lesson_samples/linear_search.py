def find_index(values, target):
    result = -1
    for index, value in enumerate(values):
        if value == target:
            result = index
            break
    return result
