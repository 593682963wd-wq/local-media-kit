from __future__ import annotations
import re
from typing import Any
MAX_TEXT_CHARS=10000
class RevivalError(ValueError):pass

def segment_script(text: str, target_chars: int = 48) -> list[dict[str, Any]]:
    cleaned = re.sub(r"[ \t]+", " ", text.strip())
    if not cleaned:
        raise RevivalError("文案不能为空")
    if len(cleaned) > MAX_TEXT_CHARS:
        raise RevivalError(f"文案不能超过 {MAX_TEXT_CHARS} 个字符")
    sentences = [item.strip() for item in re.findall(r"[^。！？；\n]+[。！？；]?", cleaned) if item.strip()]
    pieces: list[str] = []
    for sentence in sentences:
        if len(sentence) <= target_chars + 12:
            pieces.append(sentence)
            continue
        subparts = [part for part in re.findall(r"[^，,、]+[，,、]?", sentence) if part.strip()]
        pieces.extend(part.strip() for part in subparts)
    segments: list[str] = []
    current = ""
    for piece in pieces:
        if current and len(current) + len(piece) > target_chars + 8:
            segments.append(current)
            current = piece
        else:
            current += piece
    if current:
        segments.append(current)
    return [
        {
            "index": index,
            "text": value,
            "chars": len(value),
            "estimated_seconds": round(max(1.0, len(value) / 4.0), 1),
        }
        for index, value in enumerate(segments, start=1)
    ]
