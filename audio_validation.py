from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import av


class AudioValidationError(ValueError):
    pass


@dataclass(frozen=True)
class AudioMetadata:
    duration_seconds: float
    channel_count: int
    sample_rate: int
    sample_width: int
    codec_name: str
    container_format: str
    media_type: str


EXTENSION_FORMATS = {
    ".wav": {"wav"},
    ".mp3": {"mp3"},
    ".m4a": {"mov", "mp4", "m4a", "3gp", "3g2", "mj2"},
    ".aac": {"aac"},
    ".flac": {"flac"},
    ".ogg": {"ogg"},
}
MEDIA_TYPES = {
    ".wav": "audio/wav",
    ".mp3": "audio/mpeg",
    ".m4a": "audio/mp4",
    ".aac": "audio/aac",
    ".flac": "audio/flac",
    ".ogg": "audio/ogg",
}


def allowed_extensions() -> frozenset[str]:
    return frozenset(EXTENSION_FORMATS)


def inspect_audio(path: Path, *, extension: str, max_minutes: int) -> AudioMetadata:
    extension = extension.lower()
    if extension not in EXTENSION_FORMATS:
        raise AudioValidationError("不支持的音频格式")
    path = Path(path).expanduser().resolve()
    if not path.is_file():
        raise AudioValidationError("只接受明确指定的本地普通音频文件")
    try:
        container = av.open(str(path), mode="r", options={"protocol_whitelist": "file,pipe,crypto,data"})
    except (av.error.FFmpegError, OSError) as exc:
        raise AudioValidationError("文件不是可解码的音频容器") from exc
    try:
        if len(container.streams.audio) != 1:
            raise AudioValidationError("录音必须包含且只包含一个音频流")
        stream = container.streams.audio[0]
        format_names = {name.strip().lower() for name in (container.format.name or "").split(",") if name.strip()}
        if not format_names.intersection(EXTENSION_FORMATS[extension]):
            raise AudioValidationError("文件扩展名与实际音频容器不一致")
        channels = int(stream.codec_context.layout.nb_channels)
        sample_rate = int(stream.codec_context.sample_rate or 0)
        sample_width = int(getattr(stream.codec_context.format, "bytes", 0) or 0)
        codec_name = str(stream.codec_context.name or "unknown")
        if stream.duration is not None and stream.time_base is not None:
            duration = float(stream.duration * stream.time_base)
        elif container.duration is not None:
            duration = float(container.duration / av.time_base)
        else:
            raise AudioValidationError("无法确定录音时长")
        decoded_samples = 0
        for frame in container.decode(stream):
            decoded_samples += int(frame.samples)
            if decoded_samples >= max(1, sample_rate // 2):
                break
        if decoded_samples <= 0:
            raise AudioValidationError("音频无法解码或没有有效帧")
    except (av.error.FFmpegError, ValueError, OverflowError) as exc:
        if isinstance(exc, AudioValidationError):
            raise
        raise AudioValidationError("音频解码校验失败") from exc
    finally:
        container.close()
    if channels not in {1, 2}:
        raise AudioValidationError("只支持单声道或双声道录音")
    if sample_rate <= 0 or duration <= 0:
        raise AudioValidationError("音频参数无效")
    if duration > max_minutes * 60:
        raise AudioValidationError(f"录音超过 {max_minutes} 分钟上限")
    return AudioMetadata(
        duration_seconds=duration,
        channel_count=channels,
        sample_rate=sample_rate,
        sample_width=sample_width,
        codec_name=codec_name,
        container_format=sorted(format_names)[0],
        media_type=MEDIA_TYPES[extension],
    )
