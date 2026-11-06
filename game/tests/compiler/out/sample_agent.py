"""agent_retry —— 由方块编译器生成（普通 Python，仅标准库）。

来源：连接图 + 参数 + 装配层次（位置与朝向不参与编译；折叠只改视图）。
拓扑：带环、分岔    实体 10 个    连接 18 条
用法：python3 agent_retry.py（main() 自测，退出码 0 即通过）。
"""

import json
import random


def step_decide(state: dict) -> str:
    """decide：分岔条件。"""
    if state.get("route") in ("then", "else"):
        return state["route"]
    if state.get("turns", 0) >= state.get("max_turns", 4):
        return "else"
    return "then"


def step_entry(payload=None) -> dict:
    """entry：流程入口。"""
    base = payload if isinstance(payload, dict) else {}
    return {
        "seed": base.get("seed", 7),
        "attempt": 0,
        "bad_calls": 1,
        "turns": 0,
        "errors": 0,
    }


def step_generate_call(state: dict, temperature: float = 0.7) -> str:
    """generate_call：生成工具调用（示意）。"""
    if not (0.0 <= temperature <= 2.0):
        raise ValueError("generate_call.temperature 超出范围 [0.0, 2.0]")
    attempt = state.get("attempt", 0)
    if attempt < state.get("bad_calls", 0):
        return json.dumps({"tool": "scan"})  # 坏调用：缺 args，驱动校验→重试
    rng = random.Random(state.get("seed", 0) + attempt)
    tools = ("scan", "write", "none")
    return json.dumps({
        "tool": rng.choice(tools),
        "args": {"path": "/tmp/report.txt", "slot": rng.randint(0, 9)},
    })


def step_observe(state: dict) -> dict:
    """observe：通用步骤。"""
    state["turns"] = state.get("turns", 0) + 1
    state.setdefault("log", []).append("observe")
    return state


def step_parse(raw: str) -> dict:
    """parse：解析。"""
    try:
        value = json.loads(raw)
    except (TypeError, ValueError) as exc:
        raise ValueError("parse: 输入不是合法 JSON: %s" % exc) from exc
    if not isinstance(value, dict):
        raise ValueError("parse: 顶层必须是对象")
    return value


def step_recover(state: dict, max_retries: int = 3) -> dict:
    """recover：错误恢复。"""
    if not (1 <= max_retries <= 10):
        raise ValueError("recover.max_retries 超出范围 [1, 10]")
    state["errors"] = state.get("errors", 0) + 1
    state["attempt"] = state.get("attempt", 0) + 1
    if state.get("attempt", 0) > max_retries:
        state["route"] = "else"
    return state


def step_should_exit(payload: dict) -> bool:
    """should_exit：循环出口判定。"""
    return bool(payload.get("tool")) or payload.get("turns", 0) >= payload.get("max_turns", 4)


def step_summarize(payload: dict, context: dict = None) -> dict:
    """summarize：汇总。"""
    data = payload if isinstance(payload, dict) else {}
    ctx = context if isinstance(context, dict) else {}
    return {
        "status": "ok" if data.get("tool") else "gave_up",
        "tool": data.get("tool"),
        "turns": ctx.get("turns", 0),
        "tool_calls": 1 if data.get("tool") else 0,
        "errors": ctx.get("errors", 0),
    }


def step_think(state: dict, max_turns: int = 4) -> dict:
    """think：思考一步。"""
    if not (1 <= max_turns <= 64):
        raise ValueError("think.max_turns 超出范围 [1, 64]")
    state["max_turns"] = max_turns
    state["turns"] = state.get("turns", 0) + 1
    return state


def step_validate(payload: dict, required_keys: tuple = ("tool", "args")) -> None:
    """validate：schema 校验。"""
    missing = [k for k in required_keys if k not in payload]
    if missing:
        raise ValueError("validate: 缺少必需字段 %s" % ", ".join(missing))
    return None


def run(payload=None) -> dict:
    """主控制流：由 IR 生成（拓扑：带环、分岔）。"""
    errors: list = []
    v_generate_call = None  # 预声明：支路可能未走到
    v_parse = None  # 预声明：支路可能未走到
    v_think = None  # 预声明：支路可能未走到
    state = {}
    try:
        state = step_entry()
        while True:
            try:
                v_think = step_think(state, max_turns=4)
                route_decide = step_decide(v_think)
                if route_decide == "then":
                    v_generate_call = step_generate_call(v_think, temperature=0.7)
                    v_parse = step_parse(v_generate_call)
                    step_validate(v_parse, required_keys=("tool", "args"))
                    if step_should_exit(v_parse):
                        break  # 显式出口
                else:
                    state = step_observe(v_think)
                    break  # 显式出口：observe.done2 -> summarize
            except Exception as exc:
                errors.append({"loop": "agent_retry", "error": str(exc)})
                state = step_recover(state, max_retries=3)
                continue
        state = step_summarize(v_parse, v_think)
    except Exception as exc:
        errors.append({"entity": "run", "error": str(exc)})
        state = step_recover(state, max_retries=3)
        raise
    return state


def main() -> int:
    """自测入口：跑一遍 run()，断言返回 dict 并打印结果。"""
    result = run()
    assert isinstance(result, dict), "run() 必须返回 dict"
    print("agent_retry ok:", json.dumps(result, ensure_ascii=False, sort_keys=True, default=str))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
