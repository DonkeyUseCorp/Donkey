#!/usr/bin/env python3
"""Donkey local runtime sidecar runner.

The app packages this file with small executable wrappers for each runtime. It
keeps the Donkey sidecar protocol stable while allowing each runtime package to
prepare model weights and call a packaged local backend through the sidecar
protocol.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
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
MANAGED_PYTHON_ENV = "DONKEY_RUNTIME_MANAGED_PYTHON"

DEFAULT_RUNTIME_REQUIREMENTS: dict[str, list[str]] = {
    "local-llm": [
        "--no-binary llama-cpp-python",
        "llama-cpp-python>=0.3,<0.4",
    ],
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
    if operation not in {"prepareModelWeights", "healthCheck", None}:
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
    command = [
        str(venv_python),
        "-m",
        "pip",
        "install",
        "--upgrade",
        "--force-reinstall",
        "--prefer-binary",
        "--no-cache-dir",
        "-r",
        str(requirements_path),
    ]
    environment = os.environ.copy()
    environment["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"
    if RUNTIME_ID == "local-llm":
        environment.setdefault("CMAKE_ARGS", "-DGGML_METAL=OFF")
        environment.setdefault("FORCE_CMAKE", "1")
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

    target_dir = safe_model_dir(cache_dir)
    target_dir.mkdir(parents=True, exist_ok=True)

    if RUNTIME_ID == "local-llm" and not MODEL_URL:
        return error_payload(
            "missingModelWeightDownloadURL",
            {"cacheDirectory": cache_dir, "modelWeights.status": "notConfigured"},
        )

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
    return prepared(
        cache_dir,
        {
            "modelWeights.path": str(target_file),
            "modelWeights.provider": "donkey-managed-download",
        },
    )


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
    status = "ok"
    reason = ""

    if isinstance(cache_dir, str) and cache_dir:
        model_file = Path(cache_dir) / MODEL_FILENAME
        model_dir = safe_model_dir(cache_dir)
        weights_status = "cached" if model_file.exists() or any(model_dir.glob("*")) else "missing"
        if model_file.exists():
            provider = "donkey-managed-download"

    if RUNTIME_ID == "local-llm" and not os.environ.get("DONKEY_LOCAL_LLM_COMMAND"):
        status, reason, provider, extra_detail = local_llm_health_status(cache_dir, provider)
    else:
        extra_detail = ""

    extra = {
        "runtime.package": "donkey-runner-package",
        "modelWeights.status": weights_status,
        "modelWeights.provider": provider,
    }
    if reason:
        extra["reason"] = reason
    if extra_detail:
        extra["detail"] = extra_detail
    return {
        "status": status,
        "runtimeID": RUNTIME_ID,
        "runtimeVersion": RUNTIME_VERSION,
        "modelID": MODEL_ID,
        "protocolVersion": "v1",
        "metadata": metadata(extra),
    }


def local_llm_health_status(cache_dir: Any, provider: str) -> tuple[str, str, str, str]:
    if not isinstance(cache_dir, str) or not cache_dir:
        return "error", "missingCacheDirectory", provider or "llama-cpp-python", ""

    model_file = Path(cache_dir) / MODEL_FILENAME
    if not model_file.exists():
        return "error", "localLLMModelWeightsMissing", "donkey-managed-download", str(model_file)

    try:
        from llama_cpp import Llama  # type: ignore
    except Exception as exc:  # noqa: BLE001
        return "error", "localLLMBackendUnavailable", provider or "llama-cpp-python", str(exc)

    try:
        llm = Llama(
            model_path=str(model_file),
            n_ctx=local_llm_int_env("DONKEY_LOCAL_LLM_HEALTH_CONTEXT_TOKENS", 256),
            n_threads=local_llm_int_env("DONKEY_LOCAL_LLM_THREADS", max(1, os.cpu_count() or 1)),
            verbose=False,
        )
        del llm
        return "ok", "", provider or "llama-cpp-python", ""
    except Exception as exc:  # noqa: BLE001
        return "error", "localLLMGenerationBackendUnavailable", provider or "llama-cpp-python", str(exc)


def run_local_llm(request: dict[str, Any]) -> dict[str, Any]:
    cache_dir = request.get("cacheDirectory")
    model_file = Path(cache_dir) / MODEL_FILENAME if isinstance(cache_dir, str) and cache_dir else None
    if model_file is None or not model_file.exists():
        return {
            "outputText": "",
            "metadata": metadata(
                {
                    "reason": "localLLMModelWeightsMissing",
                    "modelWeights.status": "missing",
                    "modelWeights.provider": "donkey-managed-download",
                }
            ),
        }

    external_command = os.environ.get("DONKEY_LOCAL_LLM_COMMAND")
    if external_command:
        backend_request = dict(request)
        backend_metadata = dict(backend_request.get("metadata") or {})
        backend_metadata["modelWeights.path"] = str(model_file)
        backend_metadata["modelWeights.provider"] = "donkey-managed-download"
        backend_request["metadata"] = backend_metadata
        return run_external_json_command(external_command, backend_request)

    return run_llama_cpp_local_llm(request, model_file)


def run_llama_cpp_local_llm(request: dict[str, Any], model_file: Path) -> dict[str, Any]:
    try:
        from llama_cpp import Llama  # type: ignore
    except Exception as exc:  # noqa: BLE001
        return {
            "outputText": "",
            "metadata": metadata(
                {
                    "reason": "localLLMBackendUnavailable",
                    "modelWeights.status": "cached",
                    "modelWeights.path": str(model_file),
                    "modelWeights.provider": "donkey-managed-download",
                    "backend.provider": "llama-cpp-python",
                    "detail": str(exc),
                }
            ),
        }

    schema_id = str((request.get("metadata") or {}).get("schemaID") or "")
    prompt, max_tokens = local_llm_prompt_and_limit(request)
    started = time.monotonic()
    try:
        llm = Llama(
            model_path=str(model_file),
            n_ctx=local_llm_int_env("DONKEY_LOCAL_LLM_CONTEXT_TOKENS", 4096),
            n_threads=local_llm_int_env("DONKEY_LOCAL_LLM_THREADS", max(1, os.cpu_count() or 1)),
            verbose=False,
        )
        if schema_id in {"", "task_intent_v1"}:
            compact_output_text, compact_metadata = compact_task_intent_output(llm, request)
            if compact_output_text:
                latency_ms = (time.monotonic() - started) * 1000
                return {
                    "outputText": compact_output_text,
                    "metadata": metadata(
                        {
                            "local.provider": "llama-cpp-python",
                            "backend.provider": "llama-cpp-python",
                            "latency.localLLMGenerationMS": f"{latency_ms:.3f}",
                            "modelWeights.status": "cached",
                            "modelWeights.path": str(model_file),
                            "modelWeights.provider": "donkey-managed-download",
                            **compact_metadata,
                        }
                    ),
                }
        response = llm(
            prompt,
            max_tokens=max_tokens,
            temperature=0,
            top_p=0.8,
            stop=["<|im_end|>", "\n\n\n"],
        )
        latency_ms = (time.monotonic() - started) * 1000
        choices = response.get("choices") if isinstance(response, dict) else []
        output_text = ""
        if choices and isinstance(choices[0], dict):
            output_text = str(choices[0].get("text") or "").strip()
        repair_metadata: dict[str, str] = {}
        if schema_id in {"", "task_intent_v1"}:
            output_text, compact_repair_metadata = repair_invalid_task_intent_with_compact_model(
                llm,
                output_text,
                request,
            )
            repair_metadata.update(compact_repair_metadata)
            output_text, repair_metadata = repair_task_intent_output(
                output_text,
                command=str(request.get("command") or ""),
                model_id=MODEL_ID,
                context_snippets=request.get("contextSnippets", []),
            )
            repair_metadata.update(compact_repair_metadata)
        else:
            repair_metadata = {}
        return {
            "outputText": output_text,
            "metadata": metadata(
                {
                    "local.provider": "llama-cpp-python",
                    "backend.provider": "llama-cpp-python",
                    "latency.localLLMGenerationMS": f"{latency_ms:.3f}",
                    "modelWeights.status": "cached",
                    "modelWeights.path": str(model_file),
                    "modelWeights.provider": "donkey-managed-download",
                    **repair_metadata,
                }
            ),
        }
    except Exception as exc:  # noqa: BLE001
        return {
            "outputText": "",
            "metadata": metadata(
                {
                    "reason": "localLLMGenerationFailed",
                    "modelWeights.status": "cached",
                    "modelWeights.path": str(model_file),
                    "modelWeights.provider": "donkey-managed-download",
                    "backend.provider": "llama-cpp-python",
                    "detail": str(exc),
                }
            ),
        }


def local_llm_prompt_and_limit(request: dict[str, Any]) -> tuple[str, int]:
    command = str(request.get("command") or "")
    schema_id = str((request.get("metadata") or {}).get("schemaID") or "")
    if schema_id == "task_followup_resolution_v1":
        candidates = request.get("candidates", [])
        return json_prompt(
            task_followup_prompt(command, candidates),
            task_followup_schema(candidates),
        ), 160
    if schema_id == "agent_visualization_plan":
        return json_prompt(
            agent_visualization_plan_prompt(
                command,
                request.get("runtimeCapabilities", []),
                request.get("cacheSnippets", []),
            ),
            agent_visualization_plan_schema(),
        ), 320
    task_definitions = request.get("taskDefinitions", [])
    return json_prompt(
        task_intent_prompt(command, task_definitions, request.get("contextSnippets", [])),
        task_intent_schema(task_definitions),
    ), 640


def json_prompt(instructions: str, schema: dict[str, Any]) -> str:
    return "\n".join(
        [
            "<|im_start|>system",
            "You are Donkey's local structured-output command parser.",
            "Return only one valid JSON object. Do not include markdown, explanations, or thinking text.",
            "<|im_end|>",
            "<|im_start|>user",
            instructions,
            "JSON schema:",
            json.dumps(schema, separators=(",", ":")),
            "<|im_end|>",
            "<|im_start|>assistant",
        ]
    )


def local_llm_int_env(name: str, default_value: int) -> int:
    try:
        return max(1, int(os.environ.get(name, str(default_value))))
    except ValueError:
        return default_value


def repair_invalid_task_intent_with_compact_model(
    llm: Any,
    output_text: str,
    request: dict[str, Any],
) -> tuple[str, dict[str, str]]:
    if task_intent_payload_looks_valid(decode_json_object(output_text)):
        return output_text, {}

    command = str(request.get("command") or "")
    task_definitions = request.get("taskDefinitions", [])
    compact_prompt_text = compact_task_intent_prompt(command, task_definitions)
    try:
        response = llm(
            compact_prompt_text,
            max_tokens=64,
            temperature=0,
            top_p=0.8,
            stop=["<|im_end|>", "\n\n\n"],
        )
    except Exception as exc:  # noqa: BLE001
        return output_text, {"modelPlan.compactRepair": "failed", "modelPlan.compactRepair.detail": str(exc)}

    choices = response.get("choices") if isinstance(response, dict) else []
    compact_text = ""
    if choices and isinstance(choices[0], dict):
        compact_text = str(choices[0].get("text") or "").strip()
    repaired = materialize_compact_task_intent(
        compact_text,
        command=command,
        task_definitions=task_definitions,
    )
    if repaired is None:
        return output_text, {
            "modelPlan.compactRepair": "failed",
            "modelPlan.compactRepair.preview": compact_text[:160].replace("\n", "\\n"),
        }

    return json.dumps(repaired, separators=(",", ":")), {
        "modelPlan.compactRepair": "true",
        "modelPlan.compactRepair.preview": compact_text[:160].replace("\n", "\\n"),
    }


def compact_task_intent_output(llm: Any, request: dict[str, Any]) -> tuple[str, dict[str, str]]:
    command = str(request.get("command") or "")
    task_definitions = request.get("taskDefinitions", [])
    compact_prompt_text = compact_task_intent_prompt(command, task_definitions)
    try:
        response = llm(
            compact_prompt_text,
            max_tokens=64,
            temperature=0,
            top_p=0.8,
            stop=["<|im_end|>", "\n\n\n"],
        )
    except Exception as exc:  # noqa: BLE001
        return "", {"modelPlan.compactFirst": "failed", "modelPlan.compactFirst.detail": str(exc)}

    choices = response.get("choices") if isinstance(response, dict) else []
    compact_text = ""
    if choices and isinstance(choices[0], dict):
        compact_text = str(choices[0].get("text") or "").strip()
    materialized = materialize_compact_task_intent(
        compact_text,
        command=command,
        task_definitions=task_definitions,
    )
    if materialized is None:
        return "", {
            "modelPlan.compactFirst": "notMaterialized",
            "modelPlan.compactFirst.preview": compact_text[:160].replace("\n", "\\n"),
        }

    return json.dumps(materialized, separators=(",", ":")), {
        "modelPlan.compactFirst": "true",
        "modelPlan.compactFirst.preview": compact_text[:160].replace("\n", "\\n"),
    }


def task_intent_payload_looks_valid(intent: Any) -> bool:
    if not isinstance(intent, dict):
        return False
    required = [
        "taskType",
        "targetAppName",
        "entities",
        "normalizedEntities",
        "confidence",
        "needsConfirmation",
        "actionPlan",
        "metadata",
    ]
    if any(key not in intent for key in required):
        return False
    if not isinstance(intent.get("entities"), dict) or not isinstance(intent.get("normalizedEntities"), dict):
        return False
    if not isinstance(intent.get("metadata"), dict):
        return False
    action_plan = intent.get("actionPlan")
    if not isinstance(action_plan, dict):
        return False
    action_required = ["tools", "inputEntity", "controlID", "focusKey", "verification"]
    return all(key in action_plan for key in action_required) and isinstance(action_plan.get("tools"), list)


def compact_task_intent_prompt(command: str, task_definitions: list[dict[str, Any]]) -> str:
    known_apps = ["Music", "Safari", "Notes", "Numbers"]
    discovered_apps = [
        str((definition.get("targetApp") or {}).get("appName") or "").strip()
        for definition in task_definitions
        if str((definition.get("targetApp") or {}).get("appName") or "").strip()
    ]
    app_names = ordered_unique(known_apps + discovered_apps + ["Local App"])
    return "\n".join(
        [
            "<|im_start|>system",
            "Return only compact JSON with string values.",
            "<|im_end|>",
            "<|im_start|>user",
            "Classify this Mac command into one local app action.",
            "Choose appName from: " + ", ".join(app_names),
            "Prefer a concrete app name. Do not choose Local App when Music, Safari, Notes, or Numbers fits.",
            f"Command: {command}",
            "JSON keys: appName, goal, query, confidence.",
            "For music playback, appName is Music and query is the artist/song.",
            "For website navigation, appName is Safari and query is the website or URL.",
            "For writing text, appName is Notes and query is the text to write.",
            "For tables or spreadsheets, appName is Numbers and query is the table content or subject.",
            "<|im_end|>",
            "<|im_start|>assistant",
        ]
    )


def ordered_unique(values: list[str]) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for value in values:
        normalized = " ".join(normalized_words(value))
        if not normalized or normalized in seen:
            continue
        seen.add(normalized)
        result.append(value)
    return result


def materialize_compact_task_intent(
    compact_text: str,
    *,
    command: str,
    task_definitions: list[dict[str, Any]],
) -> dict[str, Any] | None:
    compact = decode_compact_object(compact_text)
    if not isinstance(compact, dict):
        return None
    if not any(str(definition.get("taskType") or "") == "local_app_interaction" for definition in task_definitions):
        return None

    app_name = str(compact.get("appName") or "").strip()
    if not app_name or normalized_words(app_name) == ["local", "app"]:
        return None
    if normalized_words(app_name) != ["music"]:
        return None

    confidence = compact_confidence(compact.get("confidence"))
    if confidence < 0.55:
        return None

    goal = str(compact.get("goal") or "").strip() or "use local app"
    if normalized_words(app_name) == ["music"]:
        goal = "play media"
    query = compact_query(compact.get("query"), command)

    return {
        "taskType": "local_app_interaction",
        "targetAppName": app_name,
        "entities": {
            "appName": app_name,
            "goal": goal,
            "query": query,
        },
        "normalizedEntities": {
            "appName": app_name,
            "goal": goal,
            "query": query,
        },
        "confidence": confidence,
        "needsConfirmation": False,
        "actionPlan": {
            "tools": [
                "app.openOrFocus",
                "app.observe",
                "ui.focusSearch",
                "ui.setText",
                "ui.pressReturn",
                "app.verifyCommand",
            ],
            "inputEntity": "query",
            "controlID": "search",
            "focusKey": "Command+F",
            "verification": "commandAttempted",
        },
        "metadata": {},
    }


def decode_compact_object(compact_text: str) -> Any:
    compact = decode_json_object(compact_text)
    if isinstance(compact, dict):
        return compact

    values: dict[str, Any] = {}
    for key in ["appName", "goal", "query", "confidence"]:
        match = re.search(rf"(?i)(?:^|[,\n])\s*{re.escape(key)}\s*:\s*([^,\n]+)", compact_text)
        if match:
            values[key] = match.group(1).strip().strip("\"'")
    return values if values else None


def compact_confidence(value: Any) -> float:
    try:
        return max(0.0, min(float(value), 1.0))
    except (TypeError, ValueError):
        return 0.7


def compact_query(value: Any, command: str) -> str:
    query = str(value or "").strip()
    query_words = normalized_words(query)
    command_words = set(normalized_words(command))
    if len(query_words) >= 2 and all(word in command_words for word in query_words):
        return query
    return command.strip()


def repair_task_intent_output(
    output_text: str,
    command: str,
    model_id: str,
    context_snippets: list[Any] | None = None,
) -> tuple[str, dict[str, str]]:
    _ = (command, model_id, context_snippets)
    intent = decode_json_object(output_text)
    if not isinstance(intent, dict):
        return output_text, {}

    output_metadata: dict[str, str] = {}
    if clear_empty_conversation_mode(intent):
        output_metadata["modelPlan.clearedEmptyConversationMode"] = "true"
    if output_metadata:
        return json.dumps(intent, separators=(",", ":")), output_metadata
    return output_text, {}


def clear_empty_conversation_mode(intent: dict[str, Any]) -> bool:
    action_plan = intent.get("actionPlan") if isinstance(intent.get("actionPlan"), dict) else {}
    tools = action_plan.get("tools") if isinstance(action_plan.get("tools"), list) else []
    metadata_value = intent.get("metadata")
    if not isinstance(metadata_value, dict):
        return False
    if not tools or metadata_value.get("responseMode") != "conversation":
        return False
    if str(metadata_value.get("assistantResponse") or "").strip():
        return False
    metadata_value.pop("responseMode", None)
    metadata_value.pop("assistantResponse", None)
    metadata_value.pop("notActionableReason", None)
    return True


def repair_app_chain_metadata(
    intent: dict[str, Any],
    *,
    command: str,
    model_id: str,
    context_snippets: list[Any],
) -> dict[str, str]:
    _ = (intent, command, model_id, context_snippets)
    return {}


def existing_app_chain(intent: dict[str, Any]) -> list[str]:
    metadata_value = intent.get("metadata") if isinstance(intent.get("metadata"), dict) else {}
    for key in ["appChain", "appSequence", "requiredAppChain"]:
        raw_value = metadata_value.get(key) if isinstance(metadata_value, dict) else None
        chain = parse_app_chain_value(raw_value)
        if chain:
            return chain
    return []


def parse_app_chain_value(value: Any) -> list[str]:
    if isinstance(value, list):
        return [str(item).strip() for item in value if str(item).strip()]
    if not isinstance(value, str) or not value.strip():
        return []
    try:
        decoded = json.loads(value)
    except json.JSONDecodeError:
        decoded = None
    if isinstance(decoded, list):
        return [str(item).strip() for item in decoded if str(item).strip()]
    for separator in ["->", ">", "|", ","]:
        if separator in value:
            return [part.strip() for part in value.split(separator) if part.strip()]
    return [value.strip()]


def should_consider_app_chain_repair(intent: dict[str, Any]) -> bool:
    if str(intent.get("taskType") or "") != "local_app_interaction":
        return False
    action_plan = intent.get("actionPlan") if isinstance(intent.get("actionPlan"), dict) else {}
    tools = action_plan.get("tools") if isinstance(action_plan.get("tools"), list) else []
    if "ui.newDocument" not in tools or "ui.setText" not in tools:
        return False
    target_words = normalized_words(target_app_name(intent))
    return target_words in (["numbers"], ["keynote"], ["pages"])


def target_app_name(intent: dict[str, Any]) -> str:
    normalized_entities = intent.get("normalizedEntities") if isinstance(intent.get("normalizedEntities"), dict) else {}
    entities = intent.get("entities") if isinstance(intent.get("entities"), dict) else {}
    return str(intent.get("targetAppName") or normalized_entities.get("appName") or entities.get("appName") or "")


def app_chain_repair_prompt(command: str, intent: dict[str, Any], context_snippets: list[Any]) -> str:
    target_app = target_app_name(intent)
    available_apps = "\n".join(str(item) for item in context_snippets[:8] if str(item).strip())
    return "\n".join(
        [
            "You repair missing multi-app chain metadata for Donkey. Return strict JSON only.",
            "Donkey has one final destination app in targetAppName, but some tasks require opening a source app first to gather or inspect information.",
            "If the command can be completed entirely in the destination app from user-provided content, set needsChain=false.",
            "If the command asks for fresh/current/reference data that should be found in another local app before creating the destination artifact, set needsChain=true.",
            "When needsChain=true, appChain must be ordered source apps first and final destination app last.",
            "Use only app names that appear in Available local apps when possible.",
            "Examples: market data or market-cap tables use Stocks before Numbers; forecast tables use Weather before Numbers; place/distance tables use Maps before Numbers.",
            f"Command: {command}",
            f"Destination app: {target_app}",
            "Current intent:",
            json.dumps(
                {
                    "taskType": intent.get("taskType"),
                    "targetAppName": intent.get("targetAppName"),
                    "entities": intent.get("entities"),
                    "normalizedEntities": intent.get("normalizedEntities"),
                    "actionPlan": intent.get("actionPlan"),
                },
                separators=(",", ":"),
            ),
            "Available local apps:",
            available_apps,
        ]
    )


def app_chain_repair_schema() -> dict[str, Any]:
    return {
        "type": "object",
        "additionalProperties": False,
        "required": ["needsChain", "appChain", "reason"],
        "properties": {
            "needsChain": {"type": "boolean"},
            "appChain": {"type": "array", "items": {"type": "string"}, "maxItems": 5},
            "reason": {"type": "string"},
        },
    }


def should_repair_document_text_payload(intent: dict[str, Any], command: str) -> bool:
    if str(intent.get("taskType") or "") != "local_app_interaction":
        return False

    app_name = str(
        intent.get("targetAppName")
        or (intent.get("normalizedEntities") or {}).get("appName")
        or (intent.get("entities") or {}).get("appName")
        or ""
    )
    if "notes" not in normalized_words(app_name):
        return False

    action_plan = intent.get("actionPlan") or {}
    tools = action_plan.get("tools") or []
    if not isinstance(tools, list) or "ui.newDocument" not in tools or "ui.setText" not in tools:
        return False
    if "ui.pressReturn" in tools:
        return False

    query = intent_query(intent).strip()
    if not query:
        return True
    if is_copied_prompt_placeholder(query):
        return True
    if command_contains_quoted(query, command):
        return False
    if any(separator in query for separator in ["\n", "\t"]):
        return False
    if re.search(r"[.?!:;,]", query):
        return False
    return len(normalized_words(query)) <= 5


def document_text_payload_prompt(command: str) -> str:
    return "\n".join(
        [
            "You repair missing document text for Donkey. Return strict JSON only.",
            "Decide whether Command clearly asks to write or generate a meaningful finished text payload for Notes.",
            "If it does, set canWrite=true and text to the final text to type. Text must be the content itself, not a label, not a restatement, and not instructions.",
            "If details are sparse but the requested writing form is clear, write a short generic finished piece for that form.",
            "If the requested object is malformed, nonsensical, or not a writing task, set canWrite=false, text=\"\", and assistantResponse to a brief clarification.",
            "Example: Command 'write a people in notes' is malformed because 'a people' is not a meaningful writing form or payload; return canWrite=false.",
            f"Command: {command}",
        ]
    )


def document_text_payload_schema() -> dict[str, Any]:
    return {
        "type": "object",
        "additionalProperties": False,
        "required": ["canWrite", "text", "assistantResponse"],
        "properties": {
            "canWrite": {"type": "boolean"},
            "text": {"type": "string"},
            "assistantResponse": {"type": "string"},
        },
    }


def decode_json_object(output_text: str) -> Any:
    try:
        return json.loads(output_text)
    except json.JSONDecodeError:
        pass

    start = output_text.find("{")
    end = output_text.rfind("}")
    if start >= 0 and end > start:
        try:
            return json.loads(output_text[start : end + 1])
        except json.JSONDecodeError:
            return None
    return None


def intent_query(intent: dict[str, Any]) -> str:
    action_plan = intent.get("actionPlan") or {}
    entity_name = str(action_plan.get("inputEntity") or "query")
    normalized_entities = intent.get("normalizedEntities") or {}
    entities = intent.get("entities") or {}
    return str(normalized_entities.get(entity_name) or normalized_entities.get("query") or entities.get(entity_name) or entities.get("query") or "")


def set_intent_query(intent: dict[str, Any], text: str) -> None:
    action_plan = intent.get("actionPlan") or {}
    entity_name = str(action_plan.get("inputEntity") or "query")
    entities = intent.setdefault("entities", {})
    normalized_entities = intent.setdefault("normalizedEntities", {})
    if isinstance(entities, dict):
        entities[entity_name] = text
    if isinstance(normalized_entities, dict):
        normalized_entities[entity_name] = text


def mark_intent_as_conversation(intent: dict[str, Any], assistant_response: str, reason: str) -> None:
    intent["confidence"] = min(float(intent.get("confidence") or 0.2), 0.2)
    intent["needsConfirmation"] = False
    intent["actionPlan"] = {
        "tools": [],
        "inputEntity": "query",
        "controlID": "",
        "focusKey": "",
        "verification": "commandAttempted",
    }
    intent_metadata = intent.setdefault("metadata", {})
    if isinstance(intent_metadata, dict):
        intent_metadata["responseMode"] = "conversation"
        intent_metadata["assistantResponse"] = assistant_response
        intent_metadata["notActionableReason"] = reason


def normalized_words(value: str) -> list[str]:
    return [word for word in re.sub(r"[^a-z0-9]+", " ", value.lower()).split() if word]


def is_copied_prompt_placeholder(query: str) -> bool:
    normalized_query = " ".join(normalized_words(query))
    phrases = [
        "complete piece of text generated for the user writing request",
        "complete piece of text generated for the user s writing request",
        "generated for the user writing request",
        "the actual final text to type",
        "tab separated rows for the requested table",
        "column a column b row label value or data needed note",
    ]
    return any(phrase in normalized_query for phrase in phrases)


def command_contains_quoted(query: str, command: str) -> bool:
    trimmed = query.strip()
    if not trimmed:
        return False
    lowered_command = command.lower()
    return any(f"{quote}{trimmed.lower()}{quote}" in lowered_command for quote in ["\"", "'", "`"])


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


def agent_visualization_plan_prompt(
    command: str,
    runtime_capabilities: list[Any],
    cache_snippets: list[Any],
) -> str:
    capabilities = "\n".join(str(item) for item in runtime_capabilities if str(item).strip())
    cache = "\n".join(str(item) for item in cache_snippets if str(item).strip())
    return "\n".join(
        [
            "Classify whether the user's request should be answered by visual-only agent action visualization.",
            "Use semantic intent, not command wording. Visual-only visualization is for teaching or demonstrating where the agent would observe, point, focus, type, submit, or verify inside an app.",
            "If the request is an executable local task, app/file open request, arithmetic/chat answer, or missing-detail clarification, set shouldVisualize=false. Normal executable tasks emit their own visualization from runtime traces.",
            "If shouldVisualize=true, generate two to five cursor steps with short labels. Coordinates are normalized screen positions from 0 to 1.",
            "The visualization must explain and point only. It must not claim to move the real mouse, click, type, submit, or perform the user's task.",
            "Do not include reasoning outside JSON.",
            f"User request: {command}",
            "Known executable runtime capabilities:",
            capabilities,
            "Relevant local cache snippets:",
            cache,
        ]
    )


def agent_visualization_plan_schema() -> dict[str, Any]:
    return {
        "type": "object",
        "additionalProperties": False,
        "required": [
            "shouldVisualize",
            "title",
            "goal",
            "targetApp",
            "confidence",
            "reason",
            "steps",
            "metadata",
        ],
        "properties": {
            "shouldVisualize": {"type": "boolean"},
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


def task_intent_prompt(
    command: str,
    task_definitions: list[dict[str, Any]],
    context_snippets: list[Any] | None = None,
) -> str:
    task_lines: list[str] = []
    for definition in task_definitions:
        target = definition.get("targetApp", {})
        definition_metadata = definition.get("metadata") or {}
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
        model_plan = ""
        if definition_metadata.get("modelPlanned") == "true":
            model_plan = " | ".join(
                [
                    "model_plan=true",
                    f"allowed_tools={definition_metadata.get('plan.allowedTools', '')}",
                    "action_plan_required=true",
                ]
            )
        parts = [
            f"task_type={definition.get('taskType')}",
            f"app={target.get('appName')}",
            f"bundle={target.get('bundleIdentifier', 'unknown')}",
            f"capability={workflow}",
            f"entities={'; '.join(entity_parts)}",
            f"dynamic_target={definition_metadata.get('dynamicTarget', 'false')}",
            model_plan,
        ]
        task_lines.append(" | ".join(item for item in parts if item))
    context = "\n".join(str(item) for item in (context_snippets or [])[:8] if str(item).strip())

    return "\n".join(
        [
            "You are Donkey's local task-intent boundary. Return strict JSON only; do not include reasoning.",
            "First decide whether Command is an executable local-app task or a conversation turn.",
            "Executable local-app task means all three are clear: action, destination or target app/item, and enough payload to execute safely.",
            "If Command is a question, conversation, malformed request, or lacks a real executable payload, do not invent one. Return the closest supported task with confidence below 0.55, needsConfirmation=false, metadata.responseMode=conversation, and metadata.assistantResponse with a brief natural-language reply.",
            "If Command is an executable local task with one ordinary missing detail, set needsConfirmation=true and include missingEntity in metadata.",
            "If Command is executable, choose by capability and target app, not exact wording. Use only provided task definitions; do not invent task types, unsupported entities, or actions.",
            "If no capability fits, return the closest supported task with confidence below 0.55.",
            "For dynamic local-item capabilities, app/file/folder names may come from the request, relevant local cache, or default-app inference; the catalog will verify availability before execution.",
            "For write/create document requests: if the requested content is malformed or not meaningful enough to type, choose conversation; do not fabricate a document payload just to make the task executable.",
            "For local_app_interaction, select the most likely local app for the user's goal, set entities.goal, and when text must be entered set entities.query plus normalizedEntities.query.",
            "For local_app_interaction, fill actionPlan.tools with allowed tools only: app.openOrFocus, app.observe, ui.newDocument, ui.focusSearch, ui.focusAddressBar, ui.focusTextEntry, ui.setText, ui.pressReturn, app.verifyCommand, app.verifyVisibleText.",
            "For website navigation, choose Safari or the user's browser, set query to the URL, use ui.focusAddressBar with controlID=addressBar and focusKey=Command+L, then ui.setText and ui.pressReturn.",
            "For writing in Notes, choose Notes, create the requested prose in query, and use ui.newDocument followed by ui.setText.",
            "For generative writing requests, query must be the complete final text to type, not a single category label, restatement of the request, or placeholder copied from these instructions.",
            "If the writing type is clear but topic/details are sparse, compose a short generic piece that satisfies the requested writing type and put that complete text in query.",
            "For spreadsheet or table creation, choose Numbers, put compact tab-separated table content in query, and use ui.newDocument followed by ui.setText. If exact live data is unavailable, make a table-shaped brief with a data-needed note; do not output a single sentence.",
            "For spreadsheet/table requests that require fresh data from another local app, set targetAppName to the final destination app and include the source-to-destination chain in metadata.appChain as a JSON string array of app names. Example: a market-cap table should use metadata.appChain=[\"Stocks\",\"Numbers\"] and targetAppName=Numbers.",
            "When ui.setText is present, entities.query and normalizedEntities.query must be non-empty.",
            "If you cannot produce non-empty text for ui.setText, choose conversation; never return ui.setText with an empty query.",
            "For sparse writing requests such as 'write a [form] in Notes', infer the requested form and write a short finished piece. If the requested object is malformed or nonsensical, choose conversation.",
            "Example malformed writing boundary: 'write a people in Notes' is not a meaningful writing form or payload, so choose conversation rather than writing a definition.",
            "entities.appName must be the human app name, such as Safari, Notes, Numbers, or Music; do not put a bundle identifier in appName.",
            "For local_app_interaction, set actionPlan.inputEntity to query when ui.setText should type the query, and set actionPlan.controlID/focusKey for the UI control strategy.",
            "actionPlan must be one nested object containing tools, inputEntity, controlID, focusKey, and verification. Do not put inputEntity, controlID, focusKey, or verification at the top level.",
            "The examples below show output structure only. Replace every example entity value with values inferred from Command and local cache; do not copy example query text unless the user asked for that exact text.",
            "Media playback output shape: targetAppName=Music, entities.appName=Music, entities.goal=play media, entities.query=<artist/song/album to play>, actionPlan.tools=[app.openOrFocus, app.observe, ui.focusSearch, ui.setText, ui.pressReturn, app.verifyCommand], inputEntity=query, controlID=search, focusKey=Command+F.",
            'Example website output shape: {"taskType":"local_app_interaction","targetAppName":"Safari","entities":{"appName":"Safari","goal":"open requested website","query":"https://example.org"},"normalizedEntities":{"appName":"Safari","goal":"open requested website","query":"https://example.org"},"confidence":0.9,"needsConfirmation":false,"actionPlan":{"tools":["app.openOrFocus","app.observe","ui.focusAddressBar","ui.setText","ui.pressReturn","app.verifyCommand"],"inputEntity":"query","controlID":"addressBar","focusKey":"Command+L","verification":"commandAttempted"},"metadata":{}}',
            "Writing output shape: targetAppName=Notes, entities.appName=Notes, entities.goal=write requested text, entities.query=<the actual final text to type>, actionPlan.tools=[app.openOrFocus, app.observe, ui.newDocument, ui.setText, app.verifyCommand], inputEntity=query, controlID=editor.",
            "Table output shape: targetAppName=Numbers, entities.appName=Numbers, entities.goal=create requested table, entities.query=<tab-separated rows for the requested table>, actionPlan.tools=[app.openOrFocus, app.observe, ui.newDocument, ui.setText, app.verifyCommand], inputEntity=query, controlID=editor.",
            'Example malformed request output shape: {"taskType":"local_app_interaction","targetAppName":"Notes","entities":{"appName":"Notes","goal":"unclear local writing request"},"normalizedEntities":{"appName":"Notes","goal":"unclear local writing request"},"confidence":0.2,"needsConfirmation":false,"actionPlan":{"tools":[],"inputEntity":"query","controlID":"","focusKey":"","verification":"commandAttempted"},"metadata":{"responseMode":"conversation","assistantResponse":"I can help, but I need a clearer thing to write before opening an app."}}',
            "For every other task type, actionPlan.tools must be empty.",
            f"Command: {command}",
            "Relevant local cache:",
            context,
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
    action_plan_schema = {
        "type": "object",
        "additionalProperties": False,
        "required": [
            "tools",
            "inputEntity",
            "controlID",
            "focusKey",
            "verification",
        ],
        "properties": {
            "tools": {
                "type": "array",
                "maxItems": 8,
                "items": {
                    "type": "string",
                    "enum": [
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
                    ],
                },
            },
            "inputEntity": {"type": "string"},
            "controlID": {"type": "string"},
            "focusKey": {"type": "string"},
            "verification": {"type": "string", "enum": ["commandAttempted", "visibleText"]},
        },
    }

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
            "actionPlan",
            "metadata",
        ],
        "properties": {
            "taskType": {"type": "string", "enum": task_types},
            "targetAppName": target_app_name_schema,
            "entities": {"type": "object", "additionalProperties": {"type": "string"}},
            "normalizedEntities": {"type": "object", "additionalProperties": {"type": "string"}},
            "confidence": {"type": "number", "minimum": 0, "maximum": 1},
            "needsConfirmation": {"type": "boolean"},
            "actionPlan": action_plan_schema,
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


if __name__ == "__main__":
    raise SystemExit(main())
