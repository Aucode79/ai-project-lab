def run(task):
    tools = ["world.snapshot", "world.inspect", "world.move", "world.pickup", "world.drop"]
    messages = [message("user", task)]
    action = model(messages, tools)
    while action["tool"] != "finish":
        messages = messages + [
            message("assistant", action),
            message("user", dispatch(action, tools)),
        ]
        action = model(messages, tools)
    return action["args"]["text"]
