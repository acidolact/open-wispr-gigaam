#!/usr/bin/env python3
"""GigaAM sidecar with whisper-server-compatible POST /inference.

The OpenWispr daemon already POSTs multipart audio to {whisperServerURL}/inference
and expects JSON {"text": "..."}. This process loads GigaAM via onnx-asr and
answers that contract, so the Swift app can A/B the model without a rebuild.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

MODEL_DEFAULT = "gigaam-v3-e2e-rnnt"


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def parse_multipart(body: bytes, content_type: str) -> dict[str, tuple[str | None, bytes]]:
    """Minimal multipart parser for whisper-server-style form-data."""
    parts: dict[str, tuple[str | None, bytes]] = {}
    if "boundary=" not in content_type:
        return parts
    boundary = content_type.split("boundary=", 1)[1].strip().strip('"').encode()
    marker = b"--" + boundary
    for raw in body.split(marker):
        raw = raw.strip(b"\r\n")
        if not raw or raw == b"--":
            continue
        header_blob, _, data = raw.partition(b"\r\n\r\n")
        if data.endswith(b"\r\n"):
            data = data[:-2]
        headers = header_blob.decode("utf-8", "replace")
        name = None
        filename = None
        for line in headers.split("\r\n"):
            if line.lower().startswith("content-disposition:"):
                for item in line.split(";"):
                    item = item.strip()
                    if item.startswith("name="):
                        name = item.split("=", 1)[1].strip('"')
                    elif item.startswith("filename="):
                        filename = item.split("=", 1)[1].strip('"')
        if name:
            parts[name] = (filename, data)
    return parts


def _warmup(model) -> None:
    """Run a 0.25 s silence clip so CoreML failures surface at load, not first request."""
    import wave

    path = tempfile.NamedTemporaryFile(suffix=".wav", delete=False).name
    try:
        with wave.open(path, "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(16000)
            wav.writeframes(b"\x00\x00" * 4000)
        transcribe_path(model, path)
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def load_asr(model_name: str, quantization: str | None, try_coreml: bool = False):
    import onnx_asr
    import onnxruntime as ort

    available = ort.get_available_providers()
    log(f"onnxruntime providers: {available}")

    kwargs: dict[str, Any] = {}
    if quantization:
        kwargs["quantization"] = quantization

    # GigaAM encoder partitions crash on CoreML EP (ORT error -1). CPU is the
    # working path; --coreml is opt-in for re-testing after runtime updates.
    if try_coreml and "CoreMLExecutionProvider" in available:
        kwargs["providers"] = ["CoreMLExecutionProvider", "CPUExecutionProvider"]
        try:
            model = onnx_asr.load_model(model_name, **kwargs)
            _warmup(model)
            log(f"loaded {model_name} via CoreML")
            return model, "CoreMLExecutionProvider"
        except Exception as exc:
            log(f"CoreML failed ({exc}); falling back to CPU")

    kwargs["providers"] = ["CPUExecutionProvider"]
    model = onnx_asr.load_model(model_name, **kwargs)
    _warmup(model)
    log(f"loaded {model_name} via CPU")
    return model, "CPUExecutionProvider"


def transcribe_path(model, path: str) -> str:
    result = model.recognize(path)
    if isinstance(result, list):
        result = " ".join(str(x) for x in result if x)
    return str(result or "").strip()


class InferenceHandler(BaseHTTPRequestHandler):
    model = None
    provider = "unknown"
    model_name = MODEL_DEFAULT

    def log_message(self, fmt: str, *args: Any) -> None:
        log("%s - " % self.address_string() + fmt % args)

    def _json(self, code: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        if self.path.rstrip("/") in ("", "/", "/health"):
            self._json(
                200,
                {
                    "status": "ok",
                    "model": self.model_name,
                    "provider": self.provider,
                },
            )
            return
        self._json(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        if not self.path.rstrip("/").endswith("/inference"):
            self._json(404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length)
        content_type = self.headers.get("Content-Type", "")
        parts = parse_multipart(body, content_type)
        file_part = parts.get("file")
        if not file_part or not file_part[1]:
            self._json(400, {"error": "missing file"})
            return
        filename, data = file_part
        suffix = Path(filename or "audio.wav").suffix or ".wav"
        tmp = tempfile.NamedTemporaryFile(suffix=suffix, delete=False)
        try:
            tmp.write(data)
            tmp.close()
            started = time.perf_counter()
            text = transcribe_path(self.model, tmp.name)
            elapsed_ms = int((time.perf_counter() - started) * 1000)
            log(f"transcribe {len(data)} bytes -> {elapsed_ms}ms chars={len(text)}")
            self._json(200, {"text": text, "elapsed_ms": elapsed_ms})
        except Exception:
            traceback.print_exc()
            self._json(500, {"error": "transcription failed"})
        finally:
            try:
                os.unlink(tmp.name)
            except OSError:
                pass


def serve(port: int, model_name: str, quantization: str | None, try_coreml: bool) -> None:
    model, provider = load_asr(model_name, quantization, try_coreml)
    InferenceHandler.model = model
    InferenceHandler.provider = provider
    InferenceHandler.model_name = model_name
    httpd = ThreadingHTTPServer(("127.0.0.1", port), InferenceHandler)
    log(f"gigaam-server listening on http://127.0.0.1:{port}/inference ({model_name}, {provider})")
    httpd.serve_forever()


def main() -> int:
    parser = argparse.ArgumentParser(description="GigaAM sidecar for open-wispr")
    parser.add_argument("--port", type=int, default=8124)
    parser.add_argument("--model", default=MODEL_DEFAULT)
    parser.add_argument(
        "--quantization",
        default="",
        help="onnx-asr quantization, e.g. int8. Empty = model default.",
    )
    parser.add_argument(
        "--coreml",
        action="store_true",
        help="Try CoreML EP first (currently crashes on GigaAM encoder; CPU is default).",
    )
    parser.add_argument("--transcribe", metavar="WAV", help="Transcribe one file and exit")
    parser.add_argument("--bench", metavar="DIR", help="Transcribe every .wav in DIR and exit")
    args = parser.parse_args()
    quantization = args.quantization.strip() or None

    if args.transcribe or args.bench:
        model, provider = load_asr(args.model, quantization, args.coreml)
        files = [args.transcribe] if args.transcribe else sorted(Path(args.bench).glob("*.wav"))
        for path in files:
            started = time.perf_counter()
            text = transcribe_path(model, str(path))
            elapsed_ms = int((time.perf_counter() - started) * 1000)
            print(
                json.dumps(
                    {
                        "file": Path(path).name,
                        "text": text,
                        "elapsed_ms": elapsed_ms,
                        "provider": provider,
                    },
                    ensure_ascii=False,
                ),
                flush=True,
            )
        return 0

    serve(args.port, args.model, quantization, args.coreml)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
