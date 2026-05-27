#!/usr/bin/env python3
"""Run task-intent JSONL evals through the local LLM sidecar protocol.

This script intentionally stays outside the Swift test target. It invokes a
sidecar command over stdin/stdout using the same request envelope as Donkey's
local task-intent runtime and scores the returned structured JSON.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any


DEFAULT_EVAL_PATH = Path("evals/task-intent/macos-default-apps-v1.jsonl")
DEFAULT_REPORT_PATH = Path("evals/task-intent/macos-default-apps-v1.latest-report.json")
DEFAULT_MODEL_CACHE_DIR = Path("evals/task-intent/model-cache")
DEFAULT_COMPARISON_DIR = Path("evals/task-intent/model-comparison")
DEFAULT_COMPARISON_REPORT_PATH = DEFAULT_COMPARISON_DIR / "comparison.latest.json"
DEFAULT_MODEL_CONFIG_PATH = Path("config/local-llm-models.json")
DEFAULT_CANDIDATE_CONFIG_PATH = Path("evals/task-intent/local-llm-model-candidates.json")
DEFAULT_SIDECAR = Path("scripts/local-runtime-runners/donkey_runtime_runner.py")
DEFAULT_SKILL_ROOT = Path("apps/Donkey/Sources/DonkeyRuntime/Resources/BuiltInSkills")
SCHEMA_ID = "task_intent_v1"


TASK_DEFINITIONS = [
    {
        "taskType": "app_open",
        "targetApp": {
            "appName": "Local Item",
            "bundleIdentifier": None,
            "titleContains": None,
            "metadata": {"dynamicTarget": "true"},
        },
        "triggerTerms": [],
        "entityRules": [
            {"name": "appName", "required": True, "aliases": {}, "metadata": {}},
        ],
        "workflowSteps": [
            {
                "id": "launch",
                "role": "launchOrFocusApp",
                "summary": "Launch or focus the model-selected local app or item",
                "metadata": {},
            }
        ],
        "observationStrategies": ["accessibility", "windowMetadata"],
        "verificationEntityName": "appName",
        "metadata": {
            "dynamicTarget": "true",
            "modelPlanned": "false",
            "catalogEntry": "generic-app-open",
        },
    },
    {
        "taskType": "local_app_interaction",
        "targetApp": {
            "appName": "Local App",
            "bundleIdentifier": None,
            "titleContains": None,
            "metadata": {"dynamicTarget": "true"},
        },
        "triggerTerms": [],
        "entityRules": [
            {"name": "appName", "required": True, "aliases": {}, "metadata": {}},
            {"name": "goal", "required": True, "aliases": {}, "metadata": {}},
            {"name": "query", "required": False, "aliases": {}, "metadata": {}},
        ],
        "workflowSteps": [
            {
                "id": "launch",
                "role": "launchOrFocusApp",
                "summary": "Launch or focus the target app",
                "metadata": {},
            },
            {
                "id": "observe",
                "role": "observeApp",
                "summary": "Observe the target app state",
                "metadata": {},
            },
            {
                "id": "focus-input",
                "role": "focusControl",
                "summary": "Focus the model-selected search, address, or text control",
                "metadata": {"controlID": "search", "key": "Command+F"},
            },
            {
                "id": "set-text",
                "role": "enterText",
                "summary": "Enter the model-selected text entity",
                "metadata": {"entityName": "query"},
            },
            {
                "id": "return",
                "role": "submit",
                "summary": "Submit the model-planned action",
                "metadata": {"key": "Return"},
            },
        ],
        "observationStrategies": [
            "accessibility",
            "windowMetadata",
            "screenshotForLocalModel",
        ],
        "verificationEntityName": "query",
        "metadata": {
            "dynamicTarget": "true",
            "modelPlanned": "true",
            "plan.allowedTools": ",".join(
                [
                    "app.openOrFocus",
                    "app.observe",
                    "ui.newDocument",
                    "ui.focusSearch",
                    "ui.focusAddressBar",
                    "ui.focusTextEntry",
                    "ui.setText",
                    "ui.pressReturn",
                    "app.verifyCommand",
                    "app.verifyVisibleText",
                ]
            ),
        },
    },
]


@dataclass
class ModelCandidate:
    id: str
    display_name: str
    model_id: str
    filename: str
    download_url: str
    expected_size_mb: float
    expected_sha256: str = ""
    notes: str = ""


@dataclass
class EvalResult:
    case_id: str
    command: str
    expected_app: str
    status: str
    issues: list[str]
    latency_ms: float
    intent: dict[str, Any] | None
    sidecar_metadata: dict[str, str]
    raw_output: str
    stderr: str


@dataclass
class LocalLLMModelConfig:
    runtime_requirements: list[str]
    default_model: ModelCandidate


@dataclass
class ModelCandidateConfig:
    candidates: list[ModelCandidate]


def load_model_config(path: Path) -> LocalLLMModelConfig:
    payload = json.loads(path.read_text(encoding="utf-8"))
    raw_model = payload.get("defaultModel")
    if not isinstance(raw_model, dict):
        raise ValueError(f"{path}: defaultModel is required")
    requirements = payload.get("runtimeRequirements") if isinstance(payload.get("runtimeRequirements"), list) else []
    return LocalLLMModelConfig(
        runtime_requirements=[str(item) for item in requirements if str(item).strip()],
        default_model=model_candidate_from_json(raw_model),
    )


def load_candidate_config(path: Path) -> ModelCandidateConfig:
    payload = json.loads(path.read_text(encoding="utf-8"))
    raw_candidates = payload.get("candidates") if isinstance(payload.get("candidates"), list) else []
    candidates = [model_candidate_from_json(item) for item in raw_candidates if isinstance(item, dict)]
    if not candidates:
        raise ValueError(f"{path}: no local LLM model candidates configured")
    return ModelCandidateConfig(candidates=candidates)


def model_candidate_from_json(payload: dict[str, Any]) -> ModelCandidate:
    return ModelCandidate(
        id=str(payload.get("id") or ""),
        display_name=str(payload.get("displayName") or payload.get("id") or ""),
        model_id=str(payload.get("modelID") or payload.get("id") or ""),
        filename=str(payload.get("filename") or "model.gguf"),
        download_url=str(payload.get("downloadURL") or ""),
        expected_size_mb=float(payload.get("expectedSizeMB") or 0),
        expected_sha256=str(payload.get("sha256") or payload.get("expectedSHA256") or ""),
        notes=str(payload.get("notes") or ""),
    )


def default_model_candidate(config: LocalLLMModelConfig) -> ModelCandidate:
    return config.default_model


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


def context_snippets(cases: list[dict[str, Any]]) -> dict[str, str]:
    snippets: dict[str, str] = {}
    for case in cases:
        app_info = case.get("app") or {}
        app_name = str(app_info.get("name") or "")
        bundle_id = str(app_info.get("bundleIdentifier") or "")
        if not app_name:
            continue
        snippet = f"{app_name} application {bundle_id}".strip()
        snippets.setdefault(app_name, snippet)
    return snippets


def skill_snippets(root: Path = DEFAULT_SKILL_ROOT) -> list[str]:
    if not root.exists():
        return []
    snippets: list[str] = []
    for path in sorted(root.glob("*/SKILL.md")):
        text = path.read_text(encoding="utf-8").strip()
        if text:
            snippets.append(text[:1200])
    return snippets


def build_request(
    case: dict[str, Any],
    model_id: str,
    snippets: dict[str, str],
    skills: list[str],
    cache_directory: Path | None = None,
) -> dict[str, Any]:
    app_info = case.get("app") or {}
    expected = case.get("expected") or {}
    app_name = str(app_info.get("name") or "")
    preferred_app_names = [
        *[str(item) for item in expected.get("requiredAppChain", [])],
        app_name,
    ]
    local_context: list[str] = []
    seen_context: set[str] = set()
    for preferred_name in preferred_app_names:
        snippet = snippets.get(preferred_name)
        if snippet and snippet not in seen_context:
            seen_context.add(snippet)
            local_context.append(snippet)
    fallback_context = [item for item in snippets.values() if item not in seen_context]
    request = {
        "command": case["command"],
        "taskDefinitions": TASK_DEFINITIONS,
        "contextSnippets": (local_context + fallback_context)[:8],
        "skillSnippets": skills[:8],
        "sourceTraceID": case["id"].replace("/", "-"),
        "modelID": model_id,
        "metadata": {
            "schemaID": SCHEMA_ID,
            "evalCaseID": case["id"],
            "evalSuiteID": case.get("suiteID", ""),
        },
    }
    if cache_directory is not None:
        request["cacheDirectory"] = str(cache_directory)
    return request


def run_sidecar(
    sidecar: Path,
    request: dict[str, Any],
    *,
    model_id: str,
    timeout_seconds: int,
    python_executable: str,
    extra_env: dict[str, str],
) -> tuple[dict[str, Any], str, float]:
    environment = os.environ.copy()
    environment.update(extra_env)
    environment.setdefault("DONKEY_RUNTIME_ID", "local-llm")
    environment.setdefault("DONKEY_MODEL_ID", model_id)
    environment.setdefault("DONKEY_RUNTIME_ROLE", "taskIntent")
    environment.setdefault("DONKEY_LOCAL_LLM_TIMEOUT_SECONDS", str(timeout_seconds))

    command = [str(sidecar)]
    if sidecar.suffix == ".py":
        command = [python_executable, str(sidecar)]

    started = time.monotonic()
    completed = subprocess.run(
        command,
        input=json.dumps(request),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=environment,
        timeout=timeout_seconds + 5,
        check=False,
    )
    latency_ms = (time.monotonic() - started) * 1_000
    if completed.returncode != 0:
        return (
            {
                "outputText": "",
                "metadata": {
                    "reason": "sidecarProcessFailed",
                    "returnCode": str(completed.returncode),
                },
            },
            completed.stderr,
            latency_ms,
        )
    try:
        return json.loads(completed.stdout or "{}"), completed.stderr, latency_ms
    except json.JSONDecodeError:
        return (
            {
                "outputText": "",
                "metadata": {
                    "reason": "sidecarInvalidJSON",
                    "stdoutPreview": completed.stdout[:500],
                },
            },
            completed.stderr,
            latency_ms,
        )


def decode_intent(output_text: str) -> dict[str, Any] | None:
    if not output_text.strip():
        return None
    try:
        value = json.loads(output_text)
        return value if isinstance(value, dict) else None
    except json.JSONDecodeError:
        start = output_text.find("{")
        end = output_text.rfind("}")
        if start >= 0 and end > start:
            try:
                value = json.loads(output_text[start : end + 1])
                return value if isinstance(value, dict) else None
            except json.JSONDecodeError:
                return None
    return None


def score_case(case: dict[str, Any], sidecar_response: dict[str, Any], stderr: str, latency_ms: float) -> EvalResult:
    expected = case["expected"]
    output_text = str(sidecar_response.get("outputText") or "")
    metadata = stringify_metadata(sidecar_response.get("metadata") or {})
    intent = decode_intent(output_text)
    issues: list[str] = []

    if intent is None:
        issues.append("invalid-or-empty-intent-json")
        return EvalResult(
            case_id=case["id"],
            command=case["command"],
            expected_app=expected["targetAppName"],
            status="failed",
            issues=issues,
            latency_ms=latency_ms,
            intent=None,
            sidecar_metadata=metadata,
            raw_output=output_text,
            stderr=stderr,
        )

    task_type = str(intent.get("taskType") or "")
    target_app_name = str(intent.get("targetAppName") or "")
    entities = intent.get("entities") if isinstance(intent.get("entities"), dict) else {}
    normalized_entities = intent.get("normalizedEntities") if isinstance(intent.get("normalizedEntities"), dict) else {}
    intent_metadata = intent.get("metadata") if isinstance(intent.get("metadata"), dict) else {}
    action_plan = intent.get("actionPlan") if isinstance(intent.get("actionPlan"), dict) else {}
    tools = action_plan.get("tools") if isinstance(action_plan.get("tools"), list) else []
    confidence = numeric_confidence(intent.get("confidence"))

    if task_type != expected["taskType"]:
        issues.append(f"task-type expected={expected['taskType']} actual={task_type}")
    if normalize_app_name(target_app_name) != normalize_app_name(expected["targetAppName"]):
        issues.append(f"target-app expected={expected['targetAppName']} actual={target_app_name}")

    app_entity = str(normalized_entities.get("appName") or entities.get("appName") or "")
    if app_entity and normalize_app_name(app_entity) != normalize_app_name(expected["appName"]):
        issues.append(f"app-entity expected={expected['appName']} actual={app_entity}")

    minimum_confidence = float(expected.get("confidenceAtLeast", 0))
    if confidence < minimum_confidence:
        issues.append(f"confidence expected>={minimum_confidence:.2f} actual={confidence:.2f}")

    expected_response_mode = expected.get("responseMode", "action")
    actual_response_mode = str(intent_metadata.get("responseMode") or "action")
    if actual_response_mode != expected_response_mode:
        issues.append(f"response-mode expected={expected_response_mode} actual={actual_response_mode}")

    missing_tools = [tool for tool in expected.get("requiredTools", []) if tool not in tools]
    if missing_tools:
        issues.append(f"missing-tools {','.join(missing_tools)}")

    unexpected_tools = [tool for tool in tools if tool not in allowed_tools()]
    if unexpected_tools:
        issues.append(f"unexpected-tools {','.join(unexpected_tools)}")

    required_app_chain = expected.get("requiredAppChain")
    if required_app_chain:
        actual_app_chain = extract_app_chain(intent)
        if not app_chain_satisfies(actual_app_chain, required_app_chain):
            issues.append(
                "app-chain expected="
                + "->".join(required_app_chain)
                + " actual="
                + ("->".join(actual_app_chain) if actual_app_chain else "<none>")
            )

    query = str(
        normalized_entities.get(action_plan.get("inputEntity") or "query")
        or normalized_entities.get("query")
        or entities.get(action_plan.get("inputEntity") or "query")
        or entities.get("query")
        or ""
    )
    if expected.get("queryOptional") is not True:
        if not query.strip():
            issues.append("missing-query")
        elif not query_matches_any(query, expected.get("queryContainsAny") or []):
            issues.append(f"query-mismatch expected-any={expected.get('queryContainsAny')} actual={query[:120]}")

    status = "passed" if not issues else "failed"
    return EvalResult(
        case_id=case["id"],
        command=case["command"],
        expected_app=expected["targetAppName"],
        status=status,
        issues=issues,
        latency_ms=latency_ms,
        intent=compact_intent(intent),
        sidecar_metadata=metadata,
        raw_output=output_text,
        stderr=stderr,
    )


def numeric_confidence(value: Any) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def normalize_app_name(value: str) -> str:
    return "".join(character.lower() for character in value if character.isalnum())


def query_matches_any(query: str, hints: list[str]) -> bool:
    normalized_query = normalize_text(query)
    return any(normalize_text(hint) in normalized_query for hint in hints)


def normalize_text(value: str) -> str:
    return " ".join("".join(character.lower() if character.isalnum() else " " for character in value).split())


def extract_app_chain(intent: dict[str, Any]) -> list[str]:
    candidates: list[Any] = []
    for key in ["appChain", "appSequence", "requiredAppChain"]:
        if key in intent:
            candidates.append(intent.get(key))

    metadata = intent.get("metadata") if isinstance(intent.get("metadata"), dict) else {}
    for key in ["appChain", "appSequence", "requiredAppChain", "sourceApps"]:
        if key in metadata:
            candidates.append(metadata.get(key))

    for candidate in candidates:
        parsed = parse_app_chain(candidate)
        if parsed:
            return parsed
    return []


def parse_app_chain(value: Any) -> list[str]:
    if isinstance(value, list):
        return [str(item).strip() for item in value if str(item).strip()]
    if not isinstance(value, str) or not value.strip():
        return []
    raw_value = value.strip()
    try:
        decoded = json.loads(raw_value)
    except json.JSONDecodeError:
        decoded = None
    if isinstance(decoded, list):
        return [str(item).strip() for item in decoded if str(item).strip()]
    for separator in ["->", ">", "|", ","]:
        if separator in raw_value:
            return [part.strip() for part in raw_value.split(separator) if part.strip()]
    return [raw_value]


def app_chain_satisfies(actual: list[str], expected: list[str]) -> bool:
    if len(actual) < len(expected):
        return False
    actual_normalized = [normalize_app_name(item) for item in actual]
    expected_normalized = [normalize_app_name(item) for item in expected]
    search_start = 0
    for expected_app in expected_normalized:
        try:
            match_index = actual_normalized.index(expected_app, search_start)
        except ValueError:
            return False
        search_start = match_index + 1
    return True


def allowed_tools() -> set[str]:
    tools: set[str] = set()
    for definition in TASK_DEFINITIONS:
        raw_tools = (definition.get("metadata") or {}).get("plan.allowedTools")
        if isinstance(raw_tools, str):
            tools.update(item.strip() for item in raw_tools.split(",") if item.strip())
    tools.add("app.openOrFocus")
    tools.add("app.verifyCommand")
    return tools


def compact_intent(intent: dict[str, Any]) -> dict[str, Any]:
    return {
        "taskType": intent.get("taskType"),
        "targetAppName": intent.get("targetAppName"),
        "confidence": intent.get("confidence"),
        "needsConfirmation": intent.get("needsConfirmation"),
        "entities": intent.get("entities"),
        "normalizedEntities": intent.get("normalizedEntities"),
        "actionPlan": intent.get("actionPlan"),
        "metadata": intent.get("metadata"),
        "appChain": extract_app_chain(intent),
    }


def stringify_metadata(value: dict[str, Any]) -> dict[str, str]:
    return {str(key): str(item) for key, item in value.items()}


def select_cases(cases: list[dict[str, Any]], app: str | None, limit: int | None) -> list[dict[str, Any]]:
    selected = cases
    if app:
        selected = [
            case for case in selected
            if normalize_app_name(str((case.get("app") or {}).get("name") or "")) == normalize_app_name(app)
        ]
    if limit is not None:
        selected = selected[:limit]
    return selected


def summarize(results: list[EvalResult], suite_id: str, model_id: str, dry_run: bool) -> dict[str, Any]:
    passed = [result for result in results if result.status == "passed"]
    failed = [result for result in results if result.status != "passed"]
    by_app: dict[str, dict[str, int]] = {}
    for result in results:
        item = by_app.setdefault(result.expected_app, {"passed": 0, "failed": 0})
        item[result.status] = item.get(result.status, 0) + 1
    return {
        "suiteID": suite_id,
        "modelID": model_id,
        "dryRun": dry_run,
        "caseCount": len(results),
        "passed": len(passed),
        "failed": len(failed),
        "passRate": (len(passed) / len(results)) if results else 0,
        "averageLatencyMS": average([result.latency_ms for result in results]),
        "byApp": dict(sorted(by_app.items())),
        "failures": [
            {
                "id": result.case_id,
                "command": result.command,
                "expectedApp": result.expected_app,
                "issues": result.issues,
                "intent": result.intent,
                "sidecarMetadata": result.sidecar_metadata,
            }
            for result in failed[:50]
        ],
    }


def average(values: list[float]) -> float | None:
    if not values:
        return None
    return sum(values) / len(values)


def candidate_by_id(config: ModelCandidateConfig) -> dict[str, ModelCandidate]:
    return {candidate.id: candidate for candidate in config.candidates}


def selected_candidates(config: ModelCandidateConfig, candidate_ids: list[str]) -> list[ModelCandidate]:
    candidates = candidate_by_id(config)
    if not candidate_ids:
        return config.candidates
    selected: list[ModelCandidate] = []
    for candidate_id in candidate_ids:
        candidate = candidates.get(candidate_id)
        if candidate is None:
            valid = ", ".join(sorted(candidates))
            raise ValueError(f"unknown candidate {candidate_id!r}; valid candidates: {valid}")
        selected.append(candidate)
    return selected


def candidate_model_dir(model_cache_dir: Path, candidate: ModelCandidate) -> Path:
    return model_cache_dir / candidate.id


def candidate_model_path(model_cache_dir: Path, candidate: ModelCandidate) -> Path:
    return candidate_model_dir(model_cache_dir, candidate) / candidate.filename


def download_candidate_model(
    candidate: ModelCandidate,
    model_cache_dir: Path,
    *,
    force: bool,
    skip_download: bool,
) -> dict[str, Any]:
    model_path = candidate_model_path(model_cache_dir, candidate)
    if skip_download:
        if not model_path.is_file():
            raise FileNotFoundError(f"{candidate.id}: cached model not found at {model_path}")
        return model_file_info(model_path, candidate)

    if model_path.is_file() and not force:
        info = model_file_info(model_path, candidate)
        if not candidate.expected_sha256 or info["sha256"] == candidate.expected_sha256:
            return info
        print(
            f"{candidate.id}: cached checksum mismatch; re-downloading {model_path.name}",
            file=sys.stderr,
        )

    model_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = model_path.with_suffix(model_path.suffix + ".download")
    tmp_path.unlink(missing_ok=True)
    print(f"{candidate.id}: downloading {candidate.download_url}", file=sys.stderr)
    digest = hashlib.sha256()
    size_bytes = 0
    with urllib.request.urlopen(candidate.download_url, timeout=60) as response, tmp_path.open("wb") as output:
        while True:
            chunk = response.read(1024 * 1024)
            if not chunk:
                break
            output.write(chunk)
            digest.update(chunk)
            size_bytes += len(chunk)
            if size_bytes and size_bytes % (64 * 1024 * 1024) < len(chunk):
                print(f"{candidate.id}: downloaded {size_bytes / 1_000_000:.0f} MB", file=sys.stderr)

    actual_sha256 = digest.hexdigest()
    if candidate.expected_sha256 and actual_sha256 != candidate.expected_sha256:
        tmp_path.unlink(missing_ok=True)
        raise RuntimeError(
            f"{candidate.id}: checksum mismatch: expected {candidate.expected_sha256}, got {actual_sha256}"
        )
    tmp_path.replace(model_path)
    return model_file_info(model_path, candidate, sha256=actual_sha256, size_bytes=size_bytes)


def model_file_info(
    model_path: Path,
    candidate: ModelCandidate,
    sha256: str | None = None,
    size_bytes: int | None = None,
) -> dict[str, Any]:
    size_bytes = model_path.stat().st_size if size_bytes is None else size_bytes
    sha256 = sha256 or sha256_file(model_path)
    return {
        "candidateID": candidate.id,
        "modelID": candidate.model_id,
        "displayName": candidate.display_name,
        "filename": candidate.filename,
        "path": str(model_path),
        "downloadURL": candidate.download_url,
        "expectedSizeMB": candidate.expected_size_mb,
        "sizeBytes": size_bytes,
        "sizeMB": size_bytes / 1_000_000,
        "sha256": sha256,
        "expectedSHA256": candidate.expected_sha256,
        "notes": candidate.notes,
    }


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as input_file:
        for chunk in iter(lambda: input_file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run_eval_suite(
    *,
    cases: list[dict[str, Any]],
    all_cases: list[dict[str, Any]],
    sidecar: Path,
    python_executable: str,
    model_id: str,
    timeout_seconds: int,
    dry_run: bool,
    report_path: Path,
    print_failures: bool,
    model_path: Path | None = None,
    cache_directory: Path | None = None,
    model_filename: str | None = None,
    runtime_state_dir: Path | None = None,
) -> tuple[dict[str, Any], list[EvalResult]]:
    snippets = context_snippets(all_cases)
    skills = skill_snippets()
    results: list[EvalResult] = []
    extra_env = {"DONKEY_LOCAL_LLM_TIMEOUT_SECONDS": str(timeout_seconds)}
    if model_path is not None:
        cache_directory = model_path.parent
        model_filename = model_path.name
    if model_filename:
        extra_env["DONKEY_MODEL_FILENAME"] = model_filename
    if runtime_state_dir is not None:
        extra_env["DONKEY_RUNTIME_STATE_DIR"] = str(runtime_state_dir)

    for index, case in enumerate(cases, start=1):
        request = build_request(case, model_id, snippets, skills, cache_directory)
        if dry_run:
            response, stderr, latency_ms = dry_run_response(case)
        else:
            print(f"[{index}/{len(cases)}] {model_id} :: {case['id']} :: {case['command']}", file=sys.stderr)
            response, stderr, latency_ms = run_sidecar(
                sidecar,
                request,
                model_id=model_id,
                timeout_seconds=timeout_seconds,
                python_executable=python_executable,
                extra_env=extra_env,
            )
        results.append(score_case(case, response, stderr, latency_ms))

    suite_id = str(cases[0].get("suiteID") or report_path.stem)
    summary = summarize(results, suite_id, model_id, dry_run)
    write_report(report_path, summary, results)
    if print_failures:
        for failure in summary["failures"]:
            print(json.dumps(failure, indent=2, sort_keys=True), file=sys.stderr)
    return summary, results


def dry_run_response(case: dict[str, Any]) -> tuple[dict[str, Any], str, float]:
    intent = {
        "taskType": case["expected"]["taskType"],
        "targetAppName": case["expected"]["targetAppName"],
        "confidence": 1.0,
        "needsConfirmation": False,
        "entities": {
            "appName": case["expected"]["appName"],
            "query": " ".join(case["expected"].get("queryContainsAny") or []),
        },
        "normalizedEntities": {
            "appName": case["expected"]["appName"],
            "query": " ".join(case["expected"].get("queryContainsAny") or []),
        },
        "actionPlan": {
            "tools": case["expected"]["requiredTools"],
            "inputEntity": "query",
            "controlID": "",
            "focusKey": "",
            "verification": "commandAttempted",
        },
        "metadata": {},
    }
    if case["expected"].get("requiredAppChain"):
        intent["metadata"]["appChain"] = json.dumps(case["expected"]["requiredAppChain"])
        intent["metadata"]["sourceApps"] = json.dumps(case["expected"].get("requiredSourceApps", []))
    return {"outputText": json.dumps(intent), "metadata": {"dryRun": "true"}}, "", 0.0


def write_report(path: Path, summary: dict[str, Any], results: list[EvalResult]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    report = {
        "summary": summary,
        "results": [
            {
                "id": result.case_id,
                "command": result.command,
                "expectedApp": result.expected_app,
                "status": result.status,
                "issues": result.issues,
                "latencyMS": result.latency_ms,
                "intent": result.intent,
                "sidecarMetadata": result.sidecar_metadata,
                "stderr": result.stderr[-1_000:] if result.stderr else "",
            }
            for result in results
        ],
    }
    path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_comparison_report(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def comparison_decision(model_summaries: list[dict[str, Any]]) -> dict[str, Any]:
    completed = [item for item in model_summaries if item.get("status") == "completed"]
    if not completed:
        return {
            "recommendedCandidateID": "",
            "recommendedModelID": "",
            "reason": "No candidate completed evaluation.",
            "policy": "passRate desc, failed asc, averageLatencyMS asc, sizeMB asc",
        }

    def sort_key(item: dict[str, Any]) -> tuple[float, int, float, float]:
        average_latency = item.get("averageLatencyMS")
        size_mb = item.get("sizeMB")
        return (
            -float(item.get("passRate") or 0),
            int(item.get("failed") or 0),
            float(average_latency) if average_latency is not None else float("inf"),
            float(size_mb) if size_mb is not None else float("inf"),
        )

    ranked = sorted(completed, key=sort_key)
    winner = ranked[0]
    return {
        "recommendedCandidateID": winner["candidateID"],
        "recommendedModelID": winner["modelID"],
        "recommendedDisplayName": winner["displayName"],
        "reason": (
            f"Selected highest pass rate ({winner['passRate']:.3f}); ties break on failures, "
            "average latency, then model size."
        ),
        "policy": "passRate desc, failed asc, averageLatencyMS asc, sizeMB asc",
    }


def run_candidate_comparison(
    args: argparse.Namespace,
    candidate_config: ModelCandidateConfig,
    cases: list[dict[str, Any]],
    all_cases: list[dict[str, Any]],
) -> int:
    candidates = selected_candidates(candidate_config, args.candidate)
    runtime_state_dir = args.model_cache_dir / ".runtime-python" / "local-llm"
    model_summaries: list[dict[str, Any]] = []

    for candidate in candidates:
        model_info: dict[str, Any] = {
            "candidateID": candidate.id,
            "modelID": candidate.model_id,
            "displayName": candidate.display_name,
            "expectedSizeMB": candidate.expected_size_mb,
            "notes": candidate.notes,
        }
        model_path: Path | None = None
        try:
            if args.dry_run:
                model_info.update({"status": "dryRun", "sizeMB": None, "sha256": ""})
            else:
                model_info.update(
                    download_candidate_model(
                        candidate,
                        args.model_cache_dir,
                        force=args.force_download,
                        skip_download=args.skip_download,
                    )
                )
                model_path = Path(str(model_info["path"]))
        except Exception as exc:  # noqa: BLE001
            model_info.update({"status": "downloadFailed", "error": str(exc)})
            model_summaries.append(model_info)
            print(f"{candidate.id}: download failed: {exc}", file=sys.stderr)
            continue

        if args.download_only:
            model_info["status"] = "downloaded"
            model_summaries.append(model_info)
            continue

        report_path = args.comparison_dir / f"{candidate.id}.report.json"
        try:
            summary, _ = run_eval_suite(
                cases=cases,
                all_cases=all_cases,
                sidecar=args.sidecar,
                python_executable=args.python,
                model_id=candidate.model_id,
                timeout_seconds=args.timeout_seconds,
                dry_run=args.dry_run,
                report_path=report_path,
                print_failures=args.print_failures,
                model_path=model_path,
                runtime_state_dir=runtime_state_dir,
            )
        except Exception as exc:  # noqa: BLE001
            model_info.update({"status": "evalFailed", "error": str(exc), "reportPath": str(report_path)})
            model_summaries.append(model_info)
            print(f"{candidate.id}: eval failed: {exc}", file=sys.stderr)
            continue

        model_info.update(
            {
                "status": "completed",
                "caseCount": summary["caseCount"],
                "passed": summary["passed"],
                "failed": summary["failed"],
                "passRate": summary["passRate"],
                "averageLatencyMS": summary["averageLatencyMS"],
                "reportPath": str(report_path),
            }
        )
        model_summaries.append(model_info)

    comparison = {
        "suiteID": str(cases[0].get("suiteID") or args.evals.stem),
        "caseCount": len(cases),
        "dryRun": args.dry_run,
        "downloadOnly": args.download_only,
        "modelCacheDir": str(args.model_cache_dir),
        "comparisonDir": str(args.comparison_dir),
        "models": sorted(
            model_summaries,
            key=lambda item: (
                -float(item.get("passRate") or 0),
                int(item.get("failed") or 0),
                optional_float(item.get("averageLatencyMS")),
                optional_float(item.get("sizeMB")),
            ),
        ),
    }
    if not args.download_only:
        comparison["decision"] = comparison_decision(model_summaries)
    write_comparison_report(args.comparison_report, comparison)
    print(json.dumps(comparison, indent=2, sort_keys=True))
    print(f"comparison report: {args.comparison_report}")
    return 0 if any(item.get("status") in {"completed", "downloaded", "dryRun"} for item in model_summaries) else 1


def optional_float(value: Any) -> float:
    if value is None:
        return float("inf")
    try:
        return float(value)
    except (TypeError, ValueError):
        return float("inf")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--evals", type=Path, default=DEFAULT_EVAL_PATH)
    parser.add_argument("--sidecar", type=Path, default=DEFAULT_SIDECAR)
    parser.add_argument("--python", default=sys.executable)
    parser.add_argument("--model-config", type=Path, default=DEFAULT_MODEL_CONFIG_PATH)
    parser.add_argument("--candidate-config", type=Path, default=DEFAULT_CANDIDATE_CONFIG_PATH)
    parser.add_argument("--model-id")
    parser.add_argument("--model-file", type=Path, help="GGUF file to use for a single-model run")
    parser.add_argument("--cache-directory", type=Path, help="cacheDirectory to pass to the sidecar for a single-model run")
    parser.add_argument("--timeout-seconds", type=int, default=35)
    parser.add_argument("--limit", type=int)
    parser.add_argument("--app", help="run only cases for one app name")
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT_PATH)
    parser.add_argument("--dry-run", action="store_true", help="build requests and validate case selection without invoking sidecar")
    parser.add_argument("--print-failures", action="store_true")
    parser.add_argument("--compare-default-candidates", action="store_true", help="download and evaluate the configured eval model candidates")
    parser.add_argument("--candidate", action="append", default=[], help="candidate id to include when comparing; repeatable")
    parser.add_argument("--model-cache-dir", type=Path, default=DEFAULT_MODEL_CACHE_DIR)
    parser.add_argument("--comparison-dir", type=Path, default=DEFAULT_COMPARISON_DIR)
    parser.add_argument("--comparison-report", type=Path, default=DEFAULT_COMPARISON_REPORT_PATH)
    parser.add_argument("--download-only", action="store_true", help="download selected comparison candidates without running evals")
    parser.add_argument("--force-download", action="store_true")
    parser.add_argument("--skip-download", action="store_true", help="use cached models only")
    args = parser.parse_args()

    all_cases = load_cases(args.evals)
    cases = select_cases(all_cases, args.app, args.limit)
    if not cases:
        print("No eval cases selected.", file=sys.stderr)
        return 2

    if args.compare_default_candidates or args.candidate:
        candidate_config = load_candidate_config(args.candidate_config)
        return run_candidate_comparison(args, candidate_config, cases, all_cases)

    model_config = load_model_config(args.model_config)
    default_candidate = default_model_candidate(model_config)
    if args.model_id is None:
        args.model_id = default_candidate.model_id

    model_path = args.model_file
    cache_directory = args.cache_directory
    if model_path is not None and cache_directory is None:
        cache_directory = model_path.parent
    runtime_state_dir = args.model_cache_dir / ".runtime-python" / "local-llm" if model_path is not None else None
    summary, _ = run_eval_suite(
        cases=cases,
        all_cases=all_cases,
        sidecar=args.sidecar,
        python_executable=args.python,
        model_id=args.model_id,
        timeout_seconds=args.timeout_seconds,
        dry_run=args.dry_run,
        report_path=args.report,
        print_failures=args.print_failures,
        model_path=model_path,
        cache_directory=cache_directory,
        runtime_state_dir=runtime_state_dir,
    )
    print(json.dumps(summary, indent=2, sort_keys=True))
    print(f"report: {args.report}")

    return 0 if summary["failed"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
