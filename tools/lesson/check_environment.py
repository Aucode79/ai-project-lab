"""Replay actual tool actions in a fresh scene; check bounds, road and delivery.

This is an environment regression check, not a second LLM success measurement.
"""
import json
import time
import ast
from run_agent import OUT, rpc

doc = json.loads((OUT / "run.json").read_text(encoding="utf-8"))
assert not rpc("move", {"node": "D"})["ok"], "non-adjacent move must fail"
for step in doc["steps"]:
    tool = step["action"].get("tool")
    if tool not in ("observe", "move", "pickup", "drop"):
        continue
    result = rpc(tool, step["action"].get("args", {}))
    assert result["ok"], (step["i"], result)
    if tool == "move" and result["state"]["carrier"] == "B":
        blocked = rpc("move", {"node": "C"})
        assert not blocked["ok"] and blocked["error"] == "road_blocked"
        assert blocked["state"]["carrier"] == "B"
time.sleep(1.0)
state = rpc("status")
assert state["state"]["carrying"] == ""
assert all(node == "D" for node in state["state"]["crates"].values())
assert len(set(state["cratePositions"].values())) == 3, "delivered crates overlap"
for name, value in state["cratePositions"].items():
    x, y, z = ast.literal_eval(value)
    assert abs(x - 4) <= 0.75 and abs(y - 0.5) < 0.01 and z < -0.5, (name, value)
print("PASS: non-adjacent and blocked moves rejected; all cargo delivered and separately visible")
