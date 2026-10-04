"""Optional pointwise cosine-similarity provider for a local Ollama service.

Only Python's standard library is required. The SQL installer embeds this file
verbatim, so the PostgreSQL server needs no Python package or module search path.
Predictions and embeddings are never cached across evaluate() invocations.
"""

import http.client
import io
import ipaddress
import json
import math
import re
import socket
import time
import urllib.parse


class ProviderError(ValueError):
    """Invalid metadata, input, HTTP response, or embedding output."""


def _reject_constant(value):
    raise ProviderError("JSON contains a non-finite number")


def _object(value, label):
    if isinstance(value, str):
        try:
            value = json.loads(value, parse_constant=_reject_constant)
        except (ValueError, TypeError) as exc:
            raise ProviderError(label + " must be a JSON object") from exc
    if not isinstance(value, dict):
        raise ProviderError(label + " must be a JSON object")
    return value


def _number(value, label, minimum, maximum):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ProviderError(label + " must be a finite number")
    try:
        number = float(value)
    except (ValueError, OverflowError) as exc:
        raise ProviderError(label + " must be a finite number") from exc
    if not math.isfinite(number) or number < minimum or number > maximum:
        raise ProviderError(label + " is outside its supported range")
    return number


def _integer(value, label, minimum, maximum):
    if isinstance(value, bool) or not isinstance(value, int):
        raise ProviderError(label + " must be an integer")
    if not minimum <= value <= maximum:
        raise ProviderError(label + " is outside its supported range")
    return value


def _digest(value):
    if not isinstance(value, str):
        raise ProviderError("model_digest must be a SHA-256 digest")
    normalized = value.removeprefix("sha256:").lower()
    if re.fullmatch(r"[0-9a-f]{64}", normalized) is None:
        raise ProviderError("model_digest must be a SHA-256 digest")
    return normalized


def _endpoint(value):
    if not isinstance(value, str):
        raise ProviderError("endpoint must be an HTTP loopback URL")
    try:
        parsed = urllib.parse.urlsplit(value)
        host = parsed.hostname
        port = 80 if parsed.port is None else parsed.port
        if (parsed.scheme != "http" or parsed.username is not None
                or parsed.password is not None or parsed.query or parsed.fragment
                or parsed.path not in ("", "/") or host is None):
            raise ValueError("unsupported URL")
        # Resolve this spelling ourselves: no DNS, proxy, or remote redirect.
        if host == "localhost":
            host = "127.0.0.1"
        address = ipaddress.ip_address(host)
        if not address.is_loopback or "%" in host or not 1 <= port <= 65535:
            raise ValueError("not a loopback address")
    except ValueError as exc:
        raise ProviderError("endpoint must be an HTTP loopback URL without credentials or a path") from exc
    return host, port


def _remaining(deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("HTTP deadline expired")
    return remaining


class _DeadlineReader(io.RawIOBase):
    """Reapply an absolute deadline on every socket read, including headers."""

    def __init__(self, connection, deadline):
        self.connection = connection
        self.deadline = deadline

    def readable(self):
        return True

    def readinto(self, buffer):
        self.connection.settimeout(_remaining(self.deadline))
        return self.connection.recv_into(buffer)


class _ResponseSocket:
    def __init__(self, connection, deadline):
        self.connection = connection
        self.deadline = deadline

    def makefile(self, mode):
        return io.BufferedReader(_DeadlineReader(self.connection, self.deadline))


def _request(endpoint, path, payload, timeout, response_limit):
    host, port = endpoint
    body = b"" if payload is None else json.dumps(
        payload, ensure_ascii=False, allow_nan=False, separators=(",", ":")
    ).encode("utf-8")
    if len(body) > 8 * 1024 * 1024:
        raise ProviderError("Ollama request exceeds the 8 MiB input limit")
    method = "GET" if payload is None else "POST"
    authority = ("[" + host + "]") if ":" in host else host
    headers = (
        method + " " + path + " HTTP/1.1\r\n"
        "Host: " + authority + ":" + str(port) + "\r\n"
        "Content-Type: application/json\r\n"
        "Accept: application/json\r\n"
        "Accept-Encoding: identity\r\n"
        "Connection: close\r\n"
        "Content-Length: " + str(len(body)) + "\r\n\r\n"
    ).encode("ascii")
    deadline = time.monotonic() + timeout
    try:
        with socket.create_connection((host, port), _remaining(deadline)) as connection:
            connection.settimeout(_remaining(deadline))
            connection.sendall(headers + body)
            response = http.client.HTTPResponse(_ResponseSocket(connection, deadline))
            try:
                response.begin()
                if response.status != 200:
                    raise ProviderError("Ollama " + path + " returned HTTP " + str(response.status))
                if response.getheader("Content-Encoding", "identity").lower() != "identity":
                    raise ProviderError("Ollama returned an unsupported content encoding")
                content_length = response.getheader("Content-Length")
                if content_length is not None:
                    try:
                        content_length = int(content_length)
                    except ValueError as exc:
                        raise ProviderError("Ollama returned an invalid Content-Length") from exc
                    if content_length < 0 or content_length > response_limit:
                        raise ProviderError("Ollama response exceeds max_response_bytes")
                chunks = bytearray()
                while True:
                    _remaining(deadline)
                    chunk = response.read(min(65536, response_limit + 1 - len(chunks)))
                    if not chunk:
                        break
                    chunks.extend(chunk)
                    if len(chunks) > response_limit:
                        raise ProviderError("Ollama response exceeds max_response_bytes")
                if content_length is not None and len(chunks) != content_length:
                    raise ProviderError("Ollama returned a truncated response body")
            finally:
                response.close()
    except (OSError, http.client.HTTPException) as exc:
        raise ProviderError("Ollama " + path + " request failed or exceeded timeout_seconds") from exc
    try:
        result = json.loads(chunks.decode("utf-8"), parse_constant=_reject_constant)
    except (UnicodeError, ValueError) as exc:
        raise ProviderError("Ollama " + path + " returned invalid JSON") from exc
    if not isinstance(result, dict) or "error" in result:
        raise ProviderError("Ollama " + path + " returned an invalid response object")
    return result


def _verify_model(endpoint, model, digest, timeout, response_limit):
    tags = _request(endpoint, "/api/tags", None, timeout, response_limit)
    models = tags.get("models")
    if not isinstance(models, list):
        raise ProviderError("Ollama /api/tags did not return a models array")
    matches = [item for item in models if isinstance(item, dict) and item.get("name") == model]
    if len(matches) != 1:
        raise ProviderError("Configured model tag is absent or ambiguous; models are never pulled automatically")
    if _digest(matches[0].get("digest")) != digest:
        raise ProviderError("Configured model_digest does not match the installed model tag")


def _normalize_vector(vector, dimensions):
    if not isinstance(vector, list) or len(vector) != dimensions:
        raise ProviderError("Embedding dimensions do not match expected_dimensions")
    values = [_number(value, "embedding component", -float("inf"), float("inf"))
              for value in vector]
    norm = math.hypot(*values)
    if not math.isfinite(norm) or norm == 0:
        raise ProviderError("Embedding must have a finite, nonzero norm")
    return [value / norm for value in values]


def evaluate(left_texts, right_texts, predicate_definition, model_config):
    """Return [(decision, similarity_score), ...] in original pair order.

    Definition: {"operation": "cosine_similarity", "threshold": [-1, 1]}.
    Config requires exact tag, SHA-256 digest and native embedding dimensions.
    The score is (cosine + 1) / 2, not a calibrated probability or confidence.
    """
    definition = _object(predicate_definition, "predicate_definition")
    config = _object(model_config, "model_config")
    if set(definition) != {"operation", "threshold"} or definition.get("operation") != "cosine_similarity":
        raise ProviderError("predicate_definition requires operation=cosine_similarity and threshold only")
    threshold = _number(definition["threshold"], "threshold", -1, 1)
    allowed_config = {"endpoint", "model", "model_digest", "expected_dimensions",
                      "timeout_seconds", "max_response_bytes"}
    if set(config) - allowed_config:
        raise ProviderError("model_config contains unsupported fields")
    model = config.get("model")
    if not isinstance(model, str) or not model or model.strip() != model or len(model) > 512:
        raise ProviderError("model must be the exact installed model tag")
    digest = _digest(config.get("model_digest"))
    dimensions = _integer(config.get("expected_dimensions"), "expected_dimensions", 1, 65536)
    endpoint = _endpoint(config.get("endpoint", "http://127.0.0.1:11434"))
    timeout = _number(config.get("timeout_seconds", 30), "timeout_seconds", 0.01, 120)
    response_limit = _integer(config.get("max_response_bytes", 4 * 1024 * 1024),
                              "max_response_bytes", 128, 64 * 1024 * 1024)
    if (not isinstance(left_texts, (list, tuple)) or not isinstance(right_texts, (list, tuple))
            or len(left_texts) != len(right_texts)):
        raise ProviderError("Provider inputs must be equally sized text arrays")
    if any(not isinstance(text, str) for text in (*left_texts, *right_texts)):
        raise ProviderError("Provider input texts must be non-NULL strings")
    if not left_texts:
        return []

    # Text reuse is byte-exact within this invocation. A single native model
    # batch covers both sides; predictions remain pointwise per original pair.
    texts = list(dict.fromkeys((*left_texts, *right_texts)))
    _verify_model(endpoint, model, digest, timeout, response_limit)
    response = _request(endpoint, "/api/embed", {
        "model": model, "input": texts, "truncate": False,
    }, timeout, response_limit)
    if response.get("model") != model:
        raise ProviderError("Embedding response model does not match the configured model tag")
    embeddings = response.get("embeddings")
    if not isinstance(embeddings, list) or len(embeddings) != len(texts):
        raise ProviderError("Ollama must return one embedding per input text")
    vectors = {text: _normalize_vector(vector, dimensions)
               for text, vector in zip(texts, embeddings)}
    # The embed API returns a name, not a digest. Checking on both sides detects
    # ordinary tag updates; administrators must keep the pinned tag immutable.
    _verify_model(endpoint, model, digest, timeout, response_limit)
    predictions = []
    for left, right in zip(left_texts, right_texts):
        cosine = 1.0 if left == right else math.fsum(
            a * b for a, b in zip(vectors[left], vectors[right])
        )
        cosine = min(1.0, max(-1.0, cosine))
        predictions.append((cosine >= threshold, (cosine + 1.0) / 2.0))
    return predictions
