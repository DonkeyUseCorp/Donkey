#!/usr/bin/env python3
"""Simulator e2e checks for Donkey agent action visualization.

The simulator exercises the feedback-loop contract without launching or
controlling real apps: intent class -> visualization plan -> grounded cursor
steps -> optional action trace -> verification report.
"""

from __future__ import annotations

import argparse
import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Any


DEFAULT_EVAL_PATH = Path("evals/agent-visualization/agent-visualization.jsonl")
DEFAULT_REPORT_PATH = Path("evals/agent-visualization/agent-visualization.latest-report.json")
CURSOR_TEST_SCREEN = {"width": 1000.0, "height": 500.0}
CURSOR_ORIGIN = {"x": 0.5, "y": 0.14}
CURSOR_TRAVEL_SECONDS = 0.4
CURSOR_HOLD_SECONDS = 0.4
CURSOR_TOLERANCE = 0.000001


@dataclass
class EvalResult:
    case_id: str
    command: str
    status: str
    issues: list[str]
    plan: dict[str, Any]


def load_cases(path: Path) -> list[dict[str, Any]]:
    cases: list[dict[str, Any]] = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if not line.strip():
            continue
        try:
            cases.append(json.loads(line))
        except json.JSONDecodeError as exc:
            raise ValueError(f"{path}:{line_number}: invalid JSONL: {exc}") from exc
    return cases


def simulator_plan(case: dict[str, Any]) -> dict[str, Any]:
    expected = case["expected"]
    target = expected["targetAppName"]
    mode = expected["executionMode"]
    kinds = list(expected.get("requiredKinds") or ["observe", "verify"])
    steps = [
        {
            "id": f"step-{index + 1}",
            "kind": kind,
            "label": label_for(kind, target),
            "target": {
                "point": {
                    "x": min(0.82, 0.30 + (index % 4) * 0.14),
                    "y": min(0.86, 0.22 + (index // 4) * 0.16),
                    "space": "normalizedTarget",
                },
                "description": target,
                "source": "dryRun",
                "confidence": 0.8,
            },
            "travelDuration": CURSOR_TRAVEL_SECONDS,
            "holdDuration": CURSOR_HOLD_SECONDS,
        }
        for index, kind in enumerate(kinds)
    ]
    verification_status = expected.get("verificationStatus") or ("verified" if mode == "live" else "unverified")
    metadata = {
        "targetApp": target,
        "realPointerMoved": "false",
        "localFirst": "true",
        "hostedModelUsed": "false",
    }
    if expected.get("requiredAppChain"):
        metadata["appChain"] = "->".join(expected["requiredAppChain"])
    if expected.get("screenshotGroundingAllowed") is False:
        metadata["screenshotGroundingAllowed"] = "false"

    plan = {
        "id": f"simulator-{case['id'].replace('/', '-')}",
        "title": f"Visualize {target}",
        "executionMode": mode,
        "sourceTraceID": case["id"].replace("/", "-"),
        "steps": steps,
        "verification": {
            "status": verification_status,
            "summary": verification_status,
            "confidence": 1.0 if verification_status == "blocked" else 0.8,
            "evidenceCount": len(steps),
        },
        "metadata": metadata,
    }
    plan["cursorPathFeedback"] = cursor_path_feedback(plan)
    return plan


def label_for(kind: str, target: str) -> str:
    labels = {
        "navigate": f"Open {target}",
        "observe": "Check the screen",
        "focusControl": "Find the right control",
        "enterText": "Enter the prepared text",
        "submit": "Submit the action",
        "verify": "Verify the result",
        "recover": "Stop on a sensitive screen",
    }
    return labels.get(kind, kind)


def score_case(case: dict[str, Any], plan: dict[str, Any]) -> EvalResult:
    expected = case["expected"]
    issues: list[str] = []
    if plan.get("executionMode") != expected.get("executionMode"):
        issues.append(f"execution-mode expected={expected.get('executionMode')} actual={plan.get('executionMode')}")
    metadata = plan.get("metadata") if isinstance(plan.get("metadata"), dict) else {}
    if normalize(metadata.get("targetApp", "")) != normalize(expected.get("targetAppName", "")):
        issues.append(f"target-app expected={expected.get('targetAppName')} actual={metadata.get('targetApp')}")
    steps = plan.get("steps") if isinstance(plan.get("steps"), list) else []
    if len(steps) < int(expected.get("minimumStepCount", 1)):
        issues.append(f"step-count expected>={expected.get('minimumStepCount')} actual={len(steps)}")
    kinds = [str(step.get("kind") or "") for step in steps if isinstance(step, dict)]
    missing_kinds = [kind for kind in expected.get("requiredKinds", []) if kind not in kinds]
    if missing_kinds:
        issues.append("missing-kinds " + ",".join(missing_kinds))
    if expected.get("mustNotMoveRealPointer") and metadata.get("realPointerMoved") != "false":
        issues.append("real-pointer-moved")
    if expected.get("requiredAppChain"):
        actual_chain = metadata.get("appChain", "")
        for app_name in expected["requiredAppChain"]:
            if normalize(app_name) not in normalize(actual_chain):
                issues.append(f"missing-app-chain {app_name}")
    expected_verification = expected.get("verificationStatus")
    actual_verification = (plan.get("verification") or {}).get("status")
    if expected_verification and actual_verification != expected_verification:
        issues.append(f"verification expected={expected_verification} actual={actual_verification}")
    if expected.get("screenshotGroundingAllowed") is False and metadata.get("screenshotGroundingAllowed") != "false":
        issues.append("screenshot-grounding-not-blocked")
    issues.extend(score_cursor_path(expected, plan))

    return EvalResult(
        case_id=case["id"],
        command=case["command"],
        status="passed" if not issues else "failed",
        issues=issues,
        plan=plan,
    )


def score_cursor_path(expected: dict[str, Any], plan: dict[str, Any]) -> list[str]:
    expected_path = expected.get("cursorPath")
    if not isinstance(expected_path, dict):
        return []

    issues: list[str] = []
    feedback = plan.get("cursorPathFeedback") if isinstance(plan.get("cursorPathFeedback"), dict) else {}
    actual_origin = feedback.get("origin", {}).get("normalized", {})
    expected_origin = expected_path.get("origin", {})
    if not same_point(actual_origin, expected_origin):
        issues.append(
            "cursor-origin expected="
            + point_label(expected_origin)
            + " actual="
            + point_label(actual_origin)
        )

    expected_targets = expected_path.get("targets") if isinstance(expected_path.get("targets"), list) else []
    steps = plan.get("steps") if isinstance(plan.get("steps"), list) else []
    if len(steps) != len(expected_targets):
        issues.append(f"cursor-target-count expected={len(expected_targets)} actual={len(steps)}")
        return issues

    arrivals = feedback.get("arrivals") if isinstance(feedback.get("arrivals"), list) else []
    midpoints = feedback.get("midpoints") if isinstance(feedback.get("midpoints"), list) else []
    for index, expected_target in enumerate(expected_targets):
        actual_target = (((steps[index] or {}).get("target") or {}).get("point") or {})
        if not same_point(actual_target, expected_target):
            issues.append(
                f"cursor-target-{index} expected={point_label(expected_target)} actual={point_label(actual_target)}"
            )
        if index >= len(arrivals):
            issues.append(f"cursor-arrival-{index}-missing")
            continue
        arrival = arrivals[index]
        expected_pixels = normalized_to_pixels(expected_target)
        actual_pixels = arrival.get("position") if isinstance(arrival.get("position"), dict) else {}
        if not same_point(actual_pixels, expected_pixels):
            issues.append(
                f"cursor-arrival-{index} expected={point_label(expected_pixels)} actual={point_label(actual_pixels)}"
            )
        if arrival.get("phase") != "travel":
            issues.append(f"cursor-arrival-{index}-phase expected=travel actual={arrival.get('phase')}")
        if not almost_equal(arrival.get("linearProgress"), 1.0):
            issues.append(f"cursor-arrival-{index}-progress actual={arrival.get('linearProgress')}")

    for index, midpoint in enumerate(midpoints):
        start = feedback["origin"]["pixels"] if index == 0 else arrivals[index - 1]["position"]
        end = arrivals[index]["position"] if index < len(arrivals) else None
        position = midpoint.get("position") if isinstance(midpoint.get("position"), dict) else {}
        if end is None or not position:
            issues.append(f"cursor-midpoint-{index}-missing")
            continue
        if distance(position, start) <= CURSOR_TOLERANCE:
            issues.append(f"cursor-midpoint-{index}-did-not-leave-start")
        if distance(position, end) <= CURSOR_TOLERANCE:
            issues.append(f"cursor-midpoint-{index}-already-at-target")
        if midpoint.get("phase") != "travel":
            issues.append(f"cursor-midpoint-{index}-phase expected=travel actual={midpoint.get('phase')}")

    return issues


def cursor_path_feedback(plan: dict[str, Any]) -> dict[str, Any]:
    elapsed = 0.0
    arrivals: list[dict[str, Any]] = []
    midpoints: list[dict[str, Any]] = []
    for step in plan["steps"]:
        travel = float(step.get("travelDuration") or CURSOR_TRAVEL_SECONDS)
        midpoint = sample_cursor(plan, quantized_time(elapsed + travel / 2))
        arrival = sample_cursor(plan, quantized_time(elapsed + travel))
        midpoints.append(midpoint)
        arrivals.append(arrival)
        elapsed = quantized_time(elapsed + travel + float(step.get("holdDuration") or CURSOR_HOLD_SECONDS))

    return {
        "screen": CURSOR_TEST_SCREEN,
        "origin": {
            "normalized": CURSOR_ORIGIN,
            "pixels": normalized_to_pixels(CURSOR_ORIGIN),
        },
        "arrivals": arrivals,
        "midpoints": midpoints,
    }


def sample_cursor(plan: dict[str, Any], elapsed: float) -> dict[str, Any]:
    remaining = quantized_time(elapsed)
    origin = normalized_to_pixels(CURSOR_ORIGIN)
    for index, step in enumerate(plan["steps"]):
        point = (((step or {}).get("target") or {}).get("point") or {})
        target = normalized_to_pixels(point)
        travel = float(step.get("travelDuration") or CURSOR_TRAVEL_SECONDS)
        if remaining <= travel:
            linear_progress = min(max(remaining / travel, 0), 1)
            eased_progress = eased(linear_progress)
            return {
                "stepIndex": index,
                "stepID": step.get("id"),
                "phase": "travel",
                "elapsed": elapsed,
                "linearProgress": linear_progress,
                "easedProgress": eased_progress,
                "position": curved_point(origin, target, eased_progress),
            }
        remaining = quantized_time(remaining - travel)

        hold = float(step.get("holdDuration") or CURSOR_HOLD_SECONDS)
        if remaining <= hold:
            wobble = math.sin(remaining * 8) * 1.8
            return {
                "stepIndex": index,
                "stepID": step.get("id"),
                "phase": "hold",
                "elapsed": elapsed,
                "linearProgress": min(max(remaining / hold, 0), 1),
                "easedProgress": min(max(remaining / hold, 0), 1),
                "position": {"x": target["x"] + wobble, "y": target["y"]},
            }
        remaining = quantized_time(remaining - hold)
        origin = target

    final_point = (((plan["steps"][-1] or {}).get("target") or {}).get("point") or CURSOR_ORIGIN)
    return {
        "stepIndex": len(plan["steps"]) - 1,
        "stepID": plan["steps"][-1].get("id"),
        "phase": "complete",
        "elapsed": elapsed,
        "linearProgress": 1.0,
        "easedProgress": 1.0,
        "position": normalized_to_pixels(final_point),
    }


def normalized_to_pixels(point: dict[str, Any]) -> dict[str, float]:
    x = min(max(float(point.get("x", 0)), 0.04), 0.96)
    y = min(max(float(point.get("y", 0)), 0.06), 0.94)
    return {"x": x * CURSOR_TEST_SCREEN["width"], "y": y * CURSOR_TEST_SCREEN["height"]}


def curved_point(origin: dict[str, float], target: dict[str, float], progress: float) -> dict[str, float]:
    dx = target["x"] - origin["x"]
    dy = target["y"] - origin["y"]
    length = max(1.0, math.hypot(dx, dy))
    curve = min(80.0, length * 0.35)
    control = {
        "x": (origin["x"] + target["x"]) / 2 + (-dy / length) * curve,
        "y": (origin["y"] + target["y"]) / 2 + (dx / length) * curve,
    }
    t = min(max(progress, 0), 1)
    inv = 1 - t
    return {
        "x": inv * inv * origin["x"] + 2 * inv * t * control["x"] + t * t * target["x"],
        "y": inv * inv * origin["y"] + 2 * inv * t * control["y"] + t * t * target["y"],
    }


def eased(progress: float) -> float:
    t = min(max(progress, 0), 1)
    return 1 - (1 - t) ** 3


def quantized_time(value: float) -> float:
    return round(value, 12)


def same_point(actual: dict[str, Any], expected: dict[str, Any]) -> bool:
    return almost_equal(actual.get("x"), expected.get("x")) and almost_equal(actual.get("y"), expected.get("y"))


def almost_equal(actual: Any, expected: Any) -> bool:
    try:
        return abs(float(actual) - float(expected)) <= CURSOR_TOLERANCE
    except (TypeError, ValueError):
        return False


def point_label(point: dict[str, Any]) -> str:
    return f"({point.get('x')},{point.get('y')})"


def distance(first: dict[str, Any], second: dict[str, Any]) -> float:
    return math.hypot(float(second["x"]) - float(first["x"]), float(second["y"]) - float(first["y"]))


def normalize(value: str) -> str:
    return "".join(character.lower() for character in str(value) if character.isalnum())


def summarize(results: list[EvalResult], mode: str, dry_run: bool) -> dict[str, Any]:
    passed = [result for result in results if result.status == "passed"]
    failed = [result for result in results if result.status != "passed"]
    return {
        "suiteID": "agent-visualization",
        "mode": mode,
        "dryRun": dry_run,
        "caseCount": len(results),
        "passed": len(passed),
        "failed": len(failed),
        "passRate": (len(passed) / len(results)) if results else 0,
        "failures": [
            {
                "id": result.case_id,
                "command": result.command,
                "issues": result.issues,
                "plan": result.plan,
            }
            for result in failed
        ],
    }


def write_report(path: Path, summary: dict[str, Any], results: list[EvalResult]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(
            {
                "summary": summary,
                "results": [
                    {
                        "id": result.case_id,
                        "command": result.command,
                        "status": result.status,
                        "issues": result.issues,
                        "plan": result.plan,
                    }
                    for result in results
                ],
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--evals", type=Path, default=DEFAULT_EVAL_PATH)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT_PATH)
    parser.add_argument("--dry-run", action="store_true", help="run without launching or controlling local apps")
    parser.add_argument("--mode", choices=["simulator"], default="simulator")
    args = parser.parse_args()

    cases = load_cases(args.evals)
    results = [score_case(case, simulator_plan(case)) for case in cases]
    summary = summarize(results, mode=args.mode, dry_run=args.dry_run)
    write_report(args.report, summary, results)
    print(json.dumps(summary, indent=2, sort_keys=True))
    print(f"report: {args.report}")
    return 0 if summary["failed"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
