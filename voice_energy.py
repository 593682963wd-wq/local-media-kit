from __future__ import annotations
import numpy as np

def _energy_timestamps(audio: np.ndarray, threshold: float) -> list[tuple[float, float]]:
    """能量阈值兜底 VAD：RMS 超阈值视为语音，返回 [(start_s, end_s)]。"""
    frame = 512
    complete = len(audio) // frame * frame
    rms = np.sqrt((audio[:complete].reshape(-1, frame) ** 2).mean(axis=1))
    if complete < len(audio):
        rms = np.append(rms, np.sqrt((audio[complete:] ** 2).mean()))
    active = rms > threshold
    if not active.any():
        return []
    ts: list[tuple[float, float]] = []
    start = None
    for i, a in enumerate(active):
        if a and start is None:
            start = i
        elif not a and start is not None:
            ts.append((start * frame / 16000, i * frame / 16000))
            start = None
    if start is not None:
        ts.append((start * frame / 16000, len(audio) / 16000))
    return ts
