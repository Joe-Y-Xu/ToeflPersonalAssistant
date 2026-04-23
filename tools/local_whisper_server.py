#!/usr/bin/env python3
"""
OpenAI-compatible local Whisper transcription service.

Endpoint:
  POST /v1/audio/transcriptions

Example:
  curl -X POST "http://127.0.0.1:9000/v1/audio/transcriptions" \
    -F "file=@sample.wav" \
    -F "model=whisper-1" \
    -F "language=en" \
    -F "response_format=json"
"""

from __future__ import annotations

import os
import tempfile
from pathlib import Path

from faster_whisper import WhisperModel
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import JSONResponse, PlainTextResponse


WHISPER_MODEL_SIZE = os.environ.get("WHISPER_MODEL_SIZE", "small")
WHISPER_COMPUTE_TYPE = os.environ.get("WHISPER_COMPUTE_TYPE", "int8")
WHISPER_DEVICE = os.environ.get("WHISPER_DEVICE", "cpu")
WHISPER_BEAM_SIZE = int(os.environ.get("WHISPER_BEAM_SIZE", "5"))

app = FastAPI(title="Local Whisper API")
model = WhisperModel(WHISPER_MODEL_SIZE, device=WHISPER_DEVICE, compute_type=WHISPER_COMPUTE_TYPE)


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/v1/audio/transcriptions")
async def transcribe(
    file: UploadFile = File(...),
    model_name: str = Form("whisper-1", alias="model"),
    language: str = Form("en"),
    response_format: str = Form("json"),
) -> JSONResponse | PlainTextResponse:
    del model_name

    suffix = Path(file.filename or "audio.caf").suffix or ".wav"
    with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as temp:
        temp_path = temp.name
        temp.write(await file.read())

    try:
        segments, _ = model.transcribe(
            temp_path,
            language=language or None,
            beam_size=WHISPER_BEAM_SIZE,
            vad_filter=True,
        )
        text = " ".join(segment.text.strip() for segment in segments).strip()
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Whisper failed: {exc}") from exc
    finally:
        try:
            os.remove(temp_path)
        except OSError:
            pass

    if response_format.lower() == "text":
        return PlainTextResponse(content=text)

    return JSONResponse(content={"text": text})
