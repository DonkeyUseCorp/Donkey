#!/usr/bin/env python3
"""Donkey local runtime sidecar runner.

The app packages this file with small executable wrappers for each runtime. It
keeps the Donkey sidecar protocol stable while allowing each runtime package to
prepare model weights and call a real local backend when the user's machine has
the required runtime installed.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


RUNTIME_ID = os.environ.get("DONKEY_RUNTIME_ID", "")
RUNTIME_VERSION = os.environ.get("DONKEY_RUNTIME_VERSION", "0.3.0-runner")
MODEL_ID = os.environ.get("DONKEY_MODEL_ID", "")
ROLE = os.environ.get("DONKEY_RUNTIME_ROLE", "")
MODEL_URL = os.environ.get("DONKEY_MODEL_URL", "")
MODEL_SHA256 = os.environ.get("DONKEY_MODEL_SHA256", "")
MODEL_FILENAME = os.environ.get("DONKEY_MODEL_FILENAME", "model.bin")
OLLAMA_ENDPOINT = os.environ.get("DONKEY_OLLAMA_ENDPOINT", "http://127.0.0.1:11434")
MANAGED_PYTHON_ENV = "DONKEY_RUNTIME_MANAGED_PYTHON"

DEFAULT_RUNTIME_REQUIREMENTS: dict[str, list[str]] = {
    "parakeet-transcriber": [
        "huggingface_hub>=0.25,<1",
    ],
    "yolo-segmenter": [
        "ultralytics>=8.3,<9",
        "opencv-python-headless>=4.10,<5",
    ],
}


def main() -> int:
    try:
        request = json.loads(sys.stdin.read() or "{}")
    except json.JSONDecodeError as exc:
        write_json(error_payload("invalidJSON", {"detail": str(exc)}))
        return 0

    operation = request.get("operation")
    managed_exit = run_with_managed_python_if_needed(operation, request)
    if managed_exit is not None:
        return managed_exit
    if operation == "prepareModelWeights":
        write_json(prepare_model_weights(request))
        return 0
    if operation == "healthCheck":
        write_json(health_check(request))
        return 0

    if RUNTIME_ID == "local-llm":
        write_json(run_local_llm(request))
        return 0
    if RUNTIME_ID == "parakeet-transcriber":
        write_json(run_parakeet(request))
        return 0
    if RUNTIME_ID == "yolo-segmenter":
        write_json(run_yolo(request))
        return 0
    if RUNTIME_ID == "ui-understander":
        write_json(run_ui_understander(request))
        return 0

    write_json(error_payload("unknownRuntime"))
    return 0


def write_json(payload: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(payload, separators=(",", ":")))


def metadata(extra: dict[str, Any] | None = None) -> dict[str, str]:
    values: dict[str, str] = {
        "runtime.package": "donkey-runner-package",
        "modelWeightsBundled": "false",
        "sidecar.role": ROLE,
    }
    if extra:
        for key, value in extra.items():
            if value is not None:
                values[key] = str(value)
    return values


def error_payload(reason: str, extra: dict[str, Any] | None = None) -> dict[str, Any]:
    return {
        "status": "error",
        "runtimeID": RUNTIME_ID,
        "modelID": MODEL_ID,
        "metadata": metadata({"reason": reason, **(extra or {})}),
    }


def run_with_managed_python_if_needed(operation: Any, request: dict[str, Any]) -> int | None:
    if os.environ.get(MANAGED_PYTHON_ENV) == "1":
        return None
    if RUNTIME_ID not in DEFAULT_RUNTIME_REQUIREMENTS:
        return None
    if operation not in {"prepareModelWeights", None}:
        return None

    requirements = runtime_requirements()
    if not requirements:
        return None

    state_dir = managed_python_state_dir(request)
    venv_python = state_dir / ".venv" / "bin" / "python"
    requirements_fingerprint = hashlib.sha256("\n".join(requirements).encode("utf-8")).hexdigest()
    stamp_file = state_dir / "requirements.sha256"

    try:
        state_dir.mkdir(parents=True, exist_ok=True)
        if not venv_python.exists():
            create_virtualenv(state_dir / ".venv")
        current_fingerprint = stamp_file.read_text().strip() if stamp_file.exists() else ""
        if current_fingerprint != requirements_fingerprint:
            install_python_requirements(venv_python, requirements, state_dir)
            stamp_file.write_text(requirements_fingerprint)
    except FileNotFoundError as exc:
        write_json(
            error_payload(
                "pythonRuntimeUnavailable",
                {"dependency": "python3", "detail": str(exc), "runtimePython.stateDirectory": str(state_dir)},
            )
        )
        return 0
    except Exception as exc:  # noqa: BLE001
        write_json(
            error_payload(
                "pythonDependencyInstallFailed",
                {"detail": str(exc), "runtimePython.stateDirectory": str(state_dir)},
            )
        )
        return 0

    environment = os.environ.copy()
    environment[MANAGED_PYTHON_ENV] = "1"
    completed = subprocess.run(
        [str(venv_python), str(Path(__file__).resolve())],
        input=json.dumps(request),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=environment,
        check=False,
    )
    if completed.returncode == 0 and completed.stdout:
        sys.stdout.write(completed.stdout)
        return 0

    write_json(
        error_payload(
            "managedPythonRuntimeFailed",
            {
                "runtimePython.stateDirectory": str(state_dir),
                "returnCode": completed.returncode,
                "stderr": completed.stderr[-800:],
            },
        )
    )
    return 0


def managed_python_state_dir(request: dict[str, Any]) -> Path:
    configured = os.environ.get("DONKEY_RUNTIME_STATE_DIR")
    if configured:
        return Path(configured)
    cache_dir = request.get("cacheDirectory")
    if isinstance(cache_dir, str) and cache_dir:
        return Path(cache_dir) / ".runtime-python"
    return Path.home() / "Library" / "Application Support" / "Donkey" / "LocalModelRuntimes" / "RuntimePython" / RUNTIME_ID


def runtime_requirements() -> list[str]:
    package_dir = os.environ.get("DONKEY_RUNTIME_PACKAGE_DIR")
    if package_dir:
        requirements_path = Path(package_dir) / "requirements.txt"
        if requirements_path.exists():
            return [
                line.strip()
                for line in requirements_path.read_text().splitlines()
                if line.strip() and not line.strip().startswith("#")
            ]
    return DEFAULT_RUNTIME_REQUIREMENTS.get(RUNTIME_ID, [])


def create_virtualenv(venv_dir: Path) -> None:
    completed = subprocess.run(
        [sys.executable, "-m", "venv", str(venv_dir)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(f"venv creation failed: {completed.stderr[-800:]}")


def install_python_requirements(venv_python: Path, requirements: list[str], state_dir: Path) -> None:
    requirements_path = state_dir / "requirements.txt"
    requirements_path.write_text("\n".join(requirements) + "\n")
    command = [str(venv_python), "-m", "pip", "install", "-r", str(requirements_path)]
    environment = os.environ.copy()
    environment["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"
    completed = subprocess.run(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=environment,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(f"pip install failed: {completed.stderr[-1200:]}")


def safe_model_dir(cache_dir: str | None = None, model_id: str | None = None) -> Path:
    root = Path(cache_dir or tempfile.gettempdir())
    safe_model = (model_id or MODEL_ID or RUNTIME_ID).replace("/", "-").replace(":", "-")
    return root / safe_model


def prepare_model_weights(request: dict[str, Any]) -> dict[str, Any]:
    cache_dir = request.get("cacheDirectory")
    if not isinstance(cache_dir, str) or not cache_dir:
        return error_payload("missingCacheDirectory")

    if RUNTIME_ID == "local-llm":
        return prepare_ollama_model(cache_dir)

    target_dir = safe_model_dir(cache_dir)
    target_dir.mkdir(parents=True, exist_ok=True)

    if RUNTIME_ID == "parakeet-transcriber" and not MODEL_URL:
        return prepare_huggingface_snapshot(cache_dir)

    if MODEL_URL:
        target_file = Path(cache_dir) / MODEL_FILENAME
        if target_file.exists() and target_file.stat().st_size > 0:
            return prepared(cache_dir, {"modelWeights.status": "cached", "modelWeights.path": str(target_file)})
        return download_model_file(MODEL_URL, target_file, MODEL_SHA256, cache_dir)

    if RUNTIME_ID == "yolo-segmenter":
        return prepare_ultralytics_model(cache_dir)

    if RUNTIME_ID == "ui-understander":
        return prepared(
            cache_dir,
            {
                "modelWeights.status": "notRequired",
                "runtime.backend": "external-ui-understander",
                "reason": "uiUnderstandingUsesPackagedAppleVisionSidecar",
            },
        )

    return error_payload(
        "missingModelWeightDownloadURL",
        {"cacheDirectory": cache_dir, "modelWeights.status": "notConfigured"},
    )


def prepared(cache_dir: str, extra: dict[str, Any] | None = None) -> dict[str, Any]:
    return {
        "status": "ok",
        "runtimeID": RUNTIME_ID,
        "modelID": MODEL_ID,
        "cacheDirectory": cache_dir,
        "metadata": metadata({"modelWeights.status": "downloaded", **(extra or {})}),
    }


def prepare_ollama_model(cache_dir: str) -> dict[str, Any]:
    if ollama_has_model(MODEL_ID):
        return prepared(
            cache_dir,
            {
                "modelWeights.status": "cached",
                "modelWeights.provider": "ollama",
                "modelWeights.ollamaModel": MODEL_ID,
            },
        )

    if shutil.which("ollama"):
        completed = subprocess.run(
            ["ollama", "pull", MODEL_ID],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        if completed.returncode == 0:
            return prepared(
                cache_dir,
                {
                    "modelWeights.provider": "ollama",
                    "modelWeights.ollamaModel": MODEL_ID,
                },
            )
        return prepared(
            cache_dir,
            {
                "reason": "ollamaPullFailed",
                "modelWeights.status": "externalUnavailable",
                "modelWeights.provider": "ollama",
                "modelWeights.ollamaModel": MODEL_ID,
                "stderr": completed.stderr[-400:],
            },
        )

    try:
        payload = json.dumps({"model": MODEL_ID, "stream": False}).encode("utf-8")
        post_json("/api/pull", payload, timeout=1800)
        return prepared(
            cache_dir,
            {
                "modelWeights.provider": "ollama",
                "modelWeights.ollamaModel": MODEL_ID,
            },
        )
    except Exception as exc:  # noqa: BLE001
        return prepared(
            cache_dir,
            {
                "reason": "ollamaUnavailable",
                "modelWeights.status": "externalUnavailable",
                "modelWeights.provider": "ollama",
                "modelWeights.ollamaModel": MODEL_ID,
                "detail": str(exc),
            },
        )


def prepare_huggingface_snapshot(cache_dir: str) -> dict[str, Any]:
    try:
        from huggingface_hub import snapshot_download  # type: ignore
    except Exception as exc:  # noqa: BLE001
        return error_payload(
            "pythonDependencyUnavailable",
            {
                "cacheDirectory": cache_dir,
                "dependency": "huggingface_hub",
                "detail": str(exc),
            },
        )

    target_dir = safe_model_dir(cache_dir)
    try:
        snapshot_path = snapshot_download(
            repo_id=MODEL_ID,
            local_dir=str(target_dir),
            local_dir_use_symlinks=False,
        )
        return prepared(
            cache_dir,
            {
                "modelWeights.status": "cached",
                "modelWeights.provider": "huggingface_hub",
                "modelWeights.path": snapshot_path,
            },
        )
    except Exception as exc:  # noqa: BLE001
        return error_payload(
            "huggingFaceSnapshotDownloadFailed",
            {"cacheDirectory": cache_dir, "detail": str(exc)},
        )


def prepare_ultralytics_model(cache_dir: str) -> dict[str, Any]:
    try:
        from ultralytics import YOLO  # type: ignore
    except Exception as exc:  # noqa: BLE001
        return error_payload(
            "pythonDependencyUnavailable",
            {"cacheDirectory": cache_dir, "dependency": "ultralytics", "detail": str(exc)},
        )

    try:
        YOLO(MODEL_ID)
        return prepared(
            cache_dir,
            {
                "modelWeights.status": "cached",
                "modelWeights.provider": "ultralytics",
            },
        )
    except Exception as exc:  # noqa: BLE001
        return error_payload(
            "ultralyticsModelPrepareFailed",
            {"cacheDirectory": cache_dir, "detail": str(exc)},
        )


def download_model_file(url: str, target_file: Path, expected_sha256: str, cache_dir: str) -> dict[str, Any]:
    target_file.parent.mkdir(parents=True, exist_ok=True)
    tmp_file = target_file.with_suffix(target_file.suffix + ".tmp")
    try:
        with urllib.request.urlopen(url, timeout=1800) as response, tmp_file.open("wb") as output:
            shutil.copyfileobj(response, output)
    except Exception as exc:  # noqa: BLE001
        tmp_file.unlink(missing_ok=True)
        return error_payload("modelWeightDownloadFailed", {"cacheDirectory": cache_dir, "detail": str(exc)})

    if expected_sha256:
        actual = sha256_file(tmp_file)
        if actual.lower() != expected_sha256.lower():
            tmp_file.unlink(missing_ok=True)
            return error_payload(
                "modelWeightChecksumMismatch",
                {"cacheDirectory": cache_dir, "expectedSHA256": expected_sha256, "actualSHA256": actual},
            )

    tmp_file.replace(target_file)
    return prepared(cache_dir, {"modelWeights.path": str(target_file)})


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as input_file:
        for chunk in iter(lambda: input_file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def health_check(request: dict[str, Any]) -> dict[str, Any]:
    cache_dir = request.get("cacheDirectory")
    weights_status = "missing"
    provider = ""

    if RUNTIME_ID == "local-llm":
        weights_status = "cached" if ollama_has_model(MODEL_ID) else "missing"
        provider = "ollama"
    elif isinstance(cache_dir, str) and cache_dir:
        model_file = Path(cache_dir) / MODEL_FILENAME
        model_dir = safe_model_dir(cache_dir)
        weights_status = "cached" if model_file.exists() or any(model_dir.glob("*")) else "missing"

    extra = {
        "runtime.package": "donkey-runner-package",
        "modelWeights.status": weights_status,
        "modelWeights.provider": provider,
    }
    return {
        "status": "ok",
        "runtimeID": RUNTIME_ID,
        "runtimeVersion": RUNTIME_VERSION,
        "modelID": MODEL_ID,
        "protocolVersion": "v1",
        "metadata": metadata(extra),
    }


def run_local_llm(request: dict[str, Any]) -> dict[str, Any]:
    command = request.get("command", "")
    schema_id = (request.get("metadata") or {}).get("schemaID", "")
    if schema_id == "task_followup_resolution_v1":
        candidates = request.get("candidates", [])
        prompt = task_followup_prompt(command, candidates)
        schema = task_followup_schema(candidates)
        max_tokens = 96
    elif schema_id == "pointer_coach_cursor_guide_v1":
        prompt = pointer_coach_cursor_guide_prompt(
            command,
            request.get("runtimeCapabilities", []),
            request.get("cacheSnippets", []),
        )
        schema = pointer_coach_cursor_guide_schema()
        max_tokens = 240
    else:
        task_definitions = request.get("taskDefinitions", [])
        prompt = task_intent_prompt(command, task_definitions)
        schema = task_intent_schema(task_definitions)
        max_tokens = 128
    body = {
        "model": request.get("modelID") or MODEL_ID,
        "prompt": prompt,
        "stream": False,
        "format": schema,
        "options": {
            "num_ctx": 2048,
            "num_predict": max_tokens,
            "temperature": 0,
            "top_p": 0.8,
        },
        "keep_alive": "10m",
    }
    started = time.monotonic()
    try:
        response = post_json("/api/generate", json.dumps(body).encode("utf-8"), timeout=4)
        latency_ms = (time.monotonic() - started) * 1000
        return {
            "outputText": response.get("response", ""),
            "metadata": metadata(
                {
                    "local.provider": "ollama-sidecar",
                    "http.status": "200",
                    "latency.localLLMGenerationMS": f"{latency_ms:.3f}",
                }
            ),
        }
    except Exception as exc:  # noqa: BLE001
        return {
            "outputText": "",
            "metadata": metadata({"reason": "localLLMGenerationFailed", "detail": str(exc)}),
        }


def task_followup_prompt(command: str, candidates: list[dict[str, Any]]) -> str:
    candidate_lines: list[str] = []
    for index, candidate in enumerate(candidates, start=1):
        events = " | ".join(
            str(event)
            for event in candidate.get("recentEvents", [])
            if str(event).strip()
        )
        assets = ", ".join(
            str(asset)
            for asset in candidate.get("assetNames", [])
            if str(asset).strip()
        )
        candidate_lines.append(
            " ; ".join(
                [
                    f"rank={index}",
                    f"taskID={candidate.get('taskID', '')}",
                    f"title={candidate.get('title', '')}",
                    f"detail={candidate.get('detail', '')}",
                    f"status={candidate.get('status', '')}",
                    f"original={candidate.get('commandText', '')}",
                    f"recentEvents={events}",
                    f"assets={assets}",
                ]
            )
        )

    return "\n".join(
        [
            "Decide whether the user's latest text is a follow-up to one recent task, then return strict JSON.",
            "Recent tasks are ordered newest first. Prefer a newer task only when it plausibly matches.",
            "A follow-up depends on previous task context, such as edits, refinements, references like it/that, answers to a question, or asset-related continuation.",
            "Do not match only because the topics are generic or the user asks for a separate new action.",
            "If no task clearly matches, set isFollowUp=false, taskID='', confidence below 0.55.",
            "Do not include reasoning outside JSON.",
            f"Latest user text: {command}",
            "Recent task candidates:",
            "\n".join(candidate_lines),
        ]
    )


def task_followup_schema(candidates: list[dict[str, Any]]) -> dict[str, Any]:
    task_ids = [str(item.get("taskID")) for item in candidates if item.get("taskID")]
    task_ids = sorted(set(task_ids + [""]))
    return {
        "type": "object",
        "additionalProperties": False,
        "required": ["isFollowUp", "taskID", "confidence", "reason"],
        "properties": {
            "isFollowUp": {"type": "boolean"},
            "taskID": {"type": "string", "enum": task_ids},
            "confidence": {"type": "number", "minimum": 0, "maximum": 1},
            "reason": {"type": "string"},
        },
    }


def pointer_coach_cursor_guide_prompt(
    command: str,
    runtime_capabilities: list[Any],
    cache_snippets: list[Any],
) -> str:
    capabilities = "\n".join(str(item) for item in runtime_capabilities if str(item).strip())
    cache = "\n".join(str(item) for item in cache_snippets if str(item).strip())
    return "\n".join(
        [
            "Classify whether the user's request should be answered by visual coaching with an on-screen cursor guide.",
            "Use semantic intent, not command wording. Visual coaching is for teaching or demonstrating where/how to do something inside an app.",
            "If the request is an executable local task, app/file open request, arithmetic/chat answer, or missing-detail clarification, set shouldShowGuide=false.",
            "If shouldShowGuide=true, generate two to five cursor steps with short labels. Coordinates are normalized screen positions from 0 to 1.",
            "The guide must explain and point only. It must not claim to click, type, submit, or perform the user's task.",
            "Do not include reasoning outside JSON.",
            f"User request: {command}",
            "Known executable runtime capabilities:",
            capabilities,
            "Relevant local cache snippets:",
            cache,
        ]
    )


def pointer_coach_cursor_guide_schema() -> dict[str, Any]:
    return {
        "type": "object",
        "additionalProperties": False,
        "required": [
            "shouldShowGuide",
            "title",
            "goal",
            "targetApp",
            "confidence",
            "reason",
            "steps",
            "metadata",
        ],
        "properties": {
            "shouldShowGuide": {"type": "boolean"},
            "title": {"type": "string"},
            "goal": {"type": "string"},
            "targetApp": {"type": "string"},
            "confidence": {"type": "number", "minimum": 0, "maximum": 1},
            "reason": {"type": "string"},
            "steps": {
                "type": "array",
                "maxItems": 5,
                "items": {
                    "type": "object",
                    "additionalProperties": False,
                    "required": ["label", "x", "y"],
                    "properties": {
                        "label": {"type": "string"},
                        "x": {"type": "number", "minimum": 0, "maximum": 1},
                        "y": {"type": "number", "minimum": 0, "maximum": 1},
                        "travelDuration": {"type": "number", "minimum": 0.1, "maximum": 2.0},
                        "holdDuration": {"type": "number", "minimum": 0.4, "maximum": 4.0},
                    },
                },
            },
            "metadata": {"type": "object", "additionalProperties": {"type": "string"}},
        },
    }


def task_intent_prompt(command: str, task_definitions: list[dict[str, Any]]) -> str:
    task_lines: list[str] = []
    for definition in task_definitions:
        target = definition.get("targetApp", {})
        entity_parts = []
        for rule in definition.get("entityRules", []):
            aliases = ",".join(sorted((rule.get("aliases") or {}).keys()))
            entity_parts.append(
                f"{rule.get('name')} required={rule.get('required', True)} aliases={aliases}"
            )
        workflow = " -> ".join(
            step.get("summary", "")
            for step in definition.get("workflowSteps", [])
            if step.get("role") != "parseIntent" and step.get("summary")
        )
        task_lines.append(
            " | ".join(
                [
                    f"task_type={definition.get('taskType')}",
                    f"app={target.get('appName')}",
                    f"bundle={target.get('bundleIdentifier', 'unknown')}",
                    f"capability={workflow}",
                    f"entities={'; '.join(entity_parts)}",
                    f"dynamic_target={(definition.get('metadata') or {}).get('dynamicTarget', 'false')}",
                ]
            )
        )

    return "\n".join(
        [
            "Classify the user's natural-language request into exactly one supported local app task intent, then return strict JSON.",
            "Choose by capability and target app, not by exact wording. The user should not need to remember command phrases.",
            "Do not include reasoning.",
            "Use only the provided task definitions. Do not invent apps, task types, entities, or actions.",
            "If no capability fits, return the closest supported task with confidence below 0.55.",
            "If a required entity is missing, set needsConfirmation=true and include missingEntity in metadata.",
            "For dynamic local-item capabilities, extract the requested local app/file/folder name into entities.appName and normalizedEntities.appName. Use targetAppName for the resolved item name when you know it.",
            f"Command: {command}",
            "Supported task capabilities:",
            "\n".join(task_lines),
        ]
    )


def task_intent_schema(task_definitions: list[dict[str, Any]]) -> dict[str, Any]:
    task_types = sorted({str(item.get("taskType")) for item in task_definitions if item.get("taskType")})
    app_names = sorted(
        {
            str((item.get("targetApp") or {}).get("appName"))
            for item in task_definitions
            if (item.get("targetApp") or {}).get("appName")
        }
    )
    allows_dynamic_targets = any(
        (item.get("metadata") or {}).get("dynamicTarget") == "true"
        for item in task_definitions
    )
    target_app_name_schema: dict[str, Any] = {"type": "string"}
    if not allows_dynamic_targets:
        target_app_name_schema["enum"] = app_names

    return {
        "type": "object",
        "additionalProperties": False,
        "required": [
            "taskType",
            "targetAppName",
            "entities",
            "normalizedEntities",
            "confidence",
            "needsConfirmation",
            "metadata",
        ],
        "properties": {
            "taskType": {"type": "string", "enum": task_types},
            "targetAppName": target_app_name_schema,
            "entities": {"type": "object", "additionalProperties": {"type": "string"}},
            "normalizedEntities": {"type": "object", "additionalProperties": {"type": "string"}},
            "confidence": {"type": "number", "minimum": 0, "maximum": 1},
            "needsConfirmation": {"type": "boolean"},
            "metadata": {"type": "object", "additionalProperties": {"type": "string"}},
        },
    }


def run_parakeet(request: dict[str, Any]) -> dict[str, Any]:
    external_command = os.environ.get("DONKEY_PARAKEET_COMMAND")
    if external_command:
        return run_external_json_command(external_command, request)

    try:
        import nemo.collections.asr as nemo_asr  # type: ignore
    except Exception as exc:  # noqa: BLE001
        return transcript_payload("", 0, {"reason": "pythonDependencyUnavailable", "dependency": "nemo_toolkit", "detail": str(exc)})

    audio_b64 = request.get("audioBase64", "")
    audio_format = request.get("format", "wav") or "wav"
    try:
        audio_bytes = base64.b64decode(audio_b64)
    except Exception as exc:  # noqa: BLE001
        return transcript_payload("", 0, {"reason": "invalidAudioBase64", "detail": str(exc)})

    suffix = "." + str(audio_format).lower().lstrip(".")
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as audio_file:
        audio_file.write(audio_bytes)
        audio_path = audio_file.name

    started = time.monotonic()
    try:
        model = nemo_asr.models.ASRModel.from_pretrained(model_name=request.get("modelID") or MODEL_ID)
        output = model.transcribe([audio_path])
        latency_ms = (time.monotonic() - started) * 1000
        text = transcription_text(output)
        return transcript_payload(
            text,
            0.8 if text else 0,
            {"runtime.backend": "nvidia-nemo", "latency.parakeetModelMS": f"{latency_ms:.3f}"},
        )
    except Exception as exc:  # noqa: BLE001
        return transcript_payload("", 0, {"reason": "parakeetTranscriptionFailed", "detail": str(exc)})
    finally:
        Path(audio_path).unlink(missing_ok=True)


def transcription_text(output: Any) -> str:
    if isinstance(output, str):
        return output.strip()
    if isinstance(output, list) and output:
        return transcription_text(output[0])
    if hasattr(output, "text"):
        return str(output.text).strip()
    return str(output or "").strip()


def transcript_payload(text: str, confidence: float, extra: dict[str, Any] | None = None) -> dict[str, Any]:
    return {
        "text": text,
        "language": None,
        "confidence": confidence,
        "segments": [text] if text else [],
        "metadata": metadata(extra),
    }


def run_yolo(request: dict[str, Any]) -> dict[str, Any]:
    external_command = os.environ.get("DONKEY_YOLO_COMMAND")
    if external_command:
        return run_external_json_command(external_command, request)

    try:
        from ultralytics import YOLO  # type: ignore
    except Exception as exc:  # noqa: BLE001
        return {"masks": [], "preprocessMS": 0, "modelInferenceMS": 0, "metadata": metadata({"reason": "pythonDependencyUnavailable", "dependency": "ultralytics", "detail": str(exc)})}

    image_path = request.get("cropImagePath")
    if not image_path:
        return {"masks": [], "preprocessMS": 0, "modelInferenceMS": 0, "metadata": metadata({"reason": "missingCropImagePath"})}

    started = time.monotonic()
    try:
        model = YOLO(MODEL_ID)
        loaded = time.monotonic()
        results = model(image_path)
        finished = time.monotonic()
        masks = yolo_masks(results)
        return {
            "masks": masks,
            "preprocessMS": (loaded - started) * 1000,
            "modelInferenceMS": (finished - loaded) * 1000,
            "metadata": metadata({"runtime.backend": "ultralytics"}),
        }
    except Exception as exc:  # noqa: BLE001
        return {"masks": [], "preprocessMS": 0, "modelInferenceMS": 0, "metadata": metadata({"reason": "yoloSegmentationFailed", "detail": str(exc)})}


def yolo_masks(results: Any) -> list[dict[str, Any]]:
    masks: list[dict[str, Any]] = []
    first = results[0] if results else None
    if first is None or getattr(first, "boxes", None) is None:
        return masks
    names = getattr(first, "names", {}) or {}
    boxes = getattr(first.boxes, "xyxy", []) or []
    confidences = getattr(first.boxes, "conf", []) or []
    classes = getattr(first.boxes, "cls", []) or []
    for index, box in enumerate(boxes):
        values = [float(v) for v in box.tolist()]
        confidence = float(confidences[index]) if index < len(confidences) else 0
        class_id = int(classes[index]) if index < len(classes) else -1
        label = str(names.get(class_id, class_id))
        masks.append(
            {
                "id": f"mask-{index}",
                "label": label,
                "bounds": {
                    "origin": {"x": values[0], "y": values[1], "space": "window"},
                    "size": {"width": max(0, values[2] - values[0]), "height": max(0, values[3] - values[1]), "space": "window"},
                },
                "confidence": confidence,
                "pointCount": 0,
                "metadata": {"classID": str(class_id)},
            }
        )
    return masks


def run_ui_understander(request: dict[str, Any]) -> dict[str, Any]:
    external_command = os.environ.get("DONKEY_UI_UNDERSTANDER_COMMAND")
    if external_command:
        return run_external_json_command(external_command, request)
    return {
        "visibleText": {},
        "controls": [],
        "formFields": [],
        "confidence": 0,
        "metadata": metadata({"reason": "uiUnderstandingRequiresPackagedAppleVisionSidecar"}),
    }


def run_external_json_command(command: str, request: dict[str, Any]) -> dict[str, Any]:
    completed = subprocess.run(
        command.split(),
        input=json.dumps(request),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        return error_payload("externalCommandFailed", {"stderr": completed.stderr[-400:]})
    try:
        payload = json.loads(completed.stdout or "{}")
    except json.JSONDecodeError:
        return error_payload("externalCommandInvalidJSON", {"stdout": completed.stdout[-400:]})
    if isinstance(payload, dict):
        return payload
    return error_payload("externalCommandInvalidPayload")


def ollama_has_model(model_id: str) -> bool:
    try:
        tags = get_json("/api/tags", timeout=3)
        models = tags.get("models", [])
        names = {item.get("name") for item in models if isinstance(item, dict)}
        return model_id in names or f"{model_id}:latest" in names
    except Exception:  # noqa: BLE001
        pass

    if shutil.which("ollama"):
        completed = subprocess.run(
            ["ollama", "list"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
        )
        if completed.returncode == 0:
            names = {line.split()[0] for line in completed.stdout.splitlines()[1:] if line.split()}
            return model_id in names
    return False


def get_json(path: str, timeout: int) -> dict[str, Any]:
    with urllib.request.urlopen(OLLAMA_ENDPOINT + path, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def post_json(path: str, payload: bytes, timeout: int) -> dict[str, Any]:
    request = urllib.request.Request(
        OLLAMA_ENDPOINT + path,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"ollama HTTP {exc.code}: {detail}") from exc


if __name__ == "__main__":
    raise SystemExit(main())
