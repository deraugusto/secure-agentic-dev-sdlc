"""L3 · model backends.

One interface, three implementations, chosen by `roles.reviewer.provider` in
inventory.yaml. Adding a fourth means writing two methods and touching nothing
else — that seam is what makes the reviewer model swappable, which is what makes
the "reviewer model is not the author model" separation maintainable rather than
a one-time configuration accident.

    offline         a canned, schema-valid verdict. No network, no model.
                    The gate mechanics are real; the review is not.
    openai-compat   POST <base>/v1/chat/completions
    ollama          POST <base>/api/chat

Credentials are never read from a file and never appear in inventory.yaml.
The inventory names an environment variable; this reads that variable.
"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request

DISCIPLINE_SLUGS = [
    "output-sanitize-drift",
    "hardcoded-secret",
    "shell-injection",
    "auth-logic-change",
    "privilege-escalation",
    "network-egress",
    "trust-boundary-crossing",
]

SEVERITIES = ("clear", "note", "concern", "block-recommended")


class BackendError(RuntimeError):
    pass


class Backend:
    """Implement ready() and complete() to add a provider."""

    name = "abstract"
    model = "unset"

    def ready(self) -> bool:
        raise NotImplementedError

    def complete(self, prompt: str, timeout: float) -> str:
        raise NotImplementedError


class OfflineBackend(Backend):
    """Deterministic canned verdict.

    Exists so a stranger's first run is green without a GPU, and so the
    negative paths are reachable without a model:

        SDLC_FORCE_UNAVAILABLE=1  ready() is false        -> defer path
        SDLC_FORCE_INVALID=1      malformed completion    -> model-error path
    """

    name = "offline"

    def __init__(self, model: str = "offline-canned") -> None:
        self.model = model

    def ready(self) -> bool:
        return os.environ.get("SDLC_FORCE_UNAVAILABLE") != "1"

    def complete(self, prompt: str, timeout: float) -> str:
        if os.environ.get("SDLC_FORCE_INVALID") == "1":
            # Six entries instead of seven, and a severity outside the enum.
            # A model losing the plot produces roughly this.
            return json.dumps({
                "annotations": [
                    {"discipline": slug, "severity": "looks-fine",
                     "file": None, "line_range": None, "rationale": ""}
                    for slug in DISCIPLINE_SLUGS[:6]
                ]
            })
        return json.dumps({
            "annotations": [
                {"discipline": slug, "severity": "clear", "file": None,
                 "line_range": None, "rationale": ""}
                for slug in DISCIPLINE_SLUGS
            ]
        })


class _HTTPBackend(Backend):
    def __init__(self, base_url: str, model: str, api_key_env: str = "") -> None:
        self.base_url = base_url.rstrip("/")
        self.model = model
        self.api_key = os.environ.get(api_key_env, "") if api_key_env else ""

    def _headers(self) -> dict:
        headers = {"Content-Type": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        return headers

    def _post(self, path: str, payload: dict, timeout: float) -> dict:
        request = urllib.request.Request(
            f"{self.base_url}{path}",
            data=json.dumps(payload).encode("utf-8"),
            headers=self._headers(),
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            raise BackendError(f"http-{exc.code}") from exc
        except (urllib.error.URLError, OSError) as exc:
            if isinstance(getattr(exc, "reason", None), TimeoutError):
                raise TimeoutError("backend-timeout") from exc
            raise BackendError(f"transport:{type(exc).__name__}") from exc
        except (json.JSONDecodeError, UnicodeDecodeError) as exc:
            raise BackendError("unparseable-response") from exc

    def _probe(self, path: str) -> bool:
        request = urllib.request.Request(
            f"{self.base_url}{path}", headers=self._headers(), method="GET")
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                return response.status < 500
        except urllib.error.HTTPError as exc:
            # 401 and 404 both prove something is listening and speaking HTTP.
            # Only a transport failure means "not ready".
            return exc.code < 500
        except (urllib.error.URLError, OSError):
            return False


class OpenAICompatBackend(_HTTPBackend):
    name = "openai-compat"

    def ready(self) -> bool:
        return self._probe("/v1/models")

    def complete(self, prompt: str, timeout: float) -> str:
        data = self._post("/v1/chat/completions", {
            "model": self.model,
            "messages": [{"role": "user", "content": prompt}],
            "temperature": 0,
        }, timeout)
        try:
            return data["choices"][0]["message"]["content"]
        except (KeyError, IndexError, TypeError) as exc:
            raise BackendError("unexpected-response-shape") from exc


class OllamaBackend(_HTTPBackend):
    name = "ollama"

    def ready(self) -> bool:
        return self._probe("/api/tags")

    def complete(self, prompt: str, timeout: float) -> str:
        data = self._post("/api/chat", {
            "model": self.model,
            "messages": [{"role": "user", "content": prompt}],
            "stream": False,
            "options": {"temperature": 0},
        }, timeout)
        try:
            return data["message"]["content"]
        except (KeyError, TypeError) as exc:
            raise BackendError("unexpected-response-shape") from exc


def build(provider: str, base_url: str, model: str,
          api_key_env: str = "") -> Backend:
    provider = (provider or "offline").strip().lower()
    if provider == "openai-compat":
        return OpenAICompatBackend(base_url, model, api_key_env)
    if provider == "ollama":
        return OllamaBackend(base_url, model, api_key_env)
    if provider == "offline":
        return OfflineBackend(model or "offline-canned")
    raise BackendError(f"unknown provider: {provider!r}")
