from __future__ import annotations
import json,re,subprocess,os,tempfile
from pathlib import Path
FFMPEG='ffmpeg'
FFPROBE='ffprobe'
LOCAL_PROTOCOLS = 'file,pipe,crypto,data'


def _local_media_path(path):
    value = os.fspath(path)
    if re.match(r'^[A-Za-z][A-Za-z0-9+.-]*:', value) and not Path(value).drive:
        raise ValueError('只接受明确指定的本地媒体文件，不接受URL或协议地址')
    return str(Path(value).expanduser().resolve())


def run(cmd,**kwargs):
    # 输入协议选项按每个输入重复设置，ffprobe位置参数也必须受限。
    cmd = list(cmd)
    if '-i' in cmd:
        guarded = [cmd[0], '-nostdin']
        for value in cmd[1:]:
            if value == '-i': guarded.extend(['-protocol_whitelist', LOCAL_PROTOCOLS])
            guarded.append(value)
        cmd = guarded
    else:
        cmd = cmd[:1] + ['-protocol_whitelist', LOCAL_PROTOCOLS] + cmd[1:]
    return subprocess.run(cmd,capture_output=True,text=True,timeout=120,**kwargs)


def probe(path):
    """返回 (时长秒, 是否有音频流, 宽, 高)"""
    r = run([FFPROBE, "-v", "quiet", "-print_format", "json",
             "-show_format", "-show_streams", _local_media_path(path)])
    if r.returncode:
        raise ValueError("媒体无法读取；仅支持本地媒体文件")
    info = json.loads(r.stdout or "{}")
    dur = float(info.get("format", {}).get("duration", 0))
    has_audio = any(s.get("codec_type") == "audio" for s in info.get("streams", []))
    w = h = 0
    for s in info.get("streams", []):
        if s.get("codec_type") == "video":
            w, h = int(s.get("width", 0)), int(s.get("height", 0))
            break
    return dur, has_audio, w, h

def detect_silences(path, threshold_db=-35, min_silence=0.5):
    """用 silencedetect 找出静音区间，返回 [(start, end), ...]"""
    r = run([FFMPEG, "-hide_banner", "-nostats", "-i", _local_media_path(path),
             "-af", f"silencedetect=noise={threshold_db}dB:d={min_silence}",
             "-f", "null", "-"])
    text = r.stderr or ""
    starts = [float(x) for x in re.findall(r"silence_start:\s*([\d.]+)", text)]
    ends = [float(x) for x in re.findall(r"silence_end:\s*([\d.]+)\s*\|", text)]
    silences = []
    for i, s in enumerate(starts):
        e = ends[i] if i < len(ends) else None
        silences.append([s, e])
    return silences

def compute_keep_segments(duration, silences, margin=0.08, min_seg=0.15):
    """由静音区间反推出要保留的片段，段之间留一点呼吸感"""
    keep = []
    cursor = 0.0
    for s, e in silences:
        end = duration if e is None else e
        if s - margin > cursor:
            keep.append([cursor, s + margin])
        cursor = max(cursor, end - margin)
    if cursor < duration:
        keep.append([cursor, duration])
    # 合并重叠、丢弃过短
    merged = []
    for seg in keep:
        if merged and seg[0] <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], seg[1])
        else:
            merged.append(seg)
    return [s for s in merged if s[1] - s[0] >= min_seg]

def cut_video(src, dst, segments, has_audio):
    """第一遍：按保留片段剪切并拼接"""
    src, dst = _local_media_path(src), _local_media_path(dst)
    parts = []
    for i, (s, e) in enumerate(segments):
        d = e - s
        if has_audio:
            parts.append(
                f"[0:v]trim=start={s:.3f}:duration={d:.3f},setpts=PTS-STARTPTS[v{i}];"
                f"[0:a]atrim=start={s:.3f}:duration={d:.3f},asetpts=PTS-STARTPTS[a{i}];"
            )
        else:
            parts.append(
                f"[0:v]trim=start={s:.3f}:duration={d:.3f},setpts=PTS-STARTPTS[v{i}];"
            )
    labels_v = "".join(f"[v{i}]" for i in range(len(segments)))
    # concat 的输入顺序是每段「视频在前、音频在后」交替排列
    labels_va = "".join(f"[v{i}][a{i}]" for i in range(len(segments)))
    if has_audio:
        parts.append(f"{labels_va}concat=n={len(segments)}:v=1:a=1[vout][aout]")
        maps = ["-map", "[vout]", "-map", "[aout]"]
    else:
        parts.append(f"{labels_v}concat=n={len(segments)}:v=1:a=0[vout]")
        maps = ["-map", "[vout]"]
    cmd = [FFMPEG, "-y", "-i", src, "-filter_complex", "".join(parts)] + maps + [
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "16",
        "-c:a", "aac", "-b:a", "192k", dst,
    ]
    r = run(cmd)
    if r.returncode != 0:
        raise RuntimeError("剪切失败:\n" + (r.stderr or "")[-1500:])

def parse_srt(path):
    """解析 SRT → [(start秒, end秒, 文本)]"""
    raw = open(path, encoding="utf-8-sig", errors="ignore").read()
    cues = []
    for block in re.split(r"\n\s*\n", raw):
        m = re.search(
            r"(\d{2}):(\d{2}):(\d{2})[,.](\d{3})\s*-->\s*(\d{2}):(\d{2}):(\d{2})[,.](\d{3})",
            block)
        if not m:
            continue
        h1, m1, s1, ms1, h2, m2, s2, ms2 = map(int, m.groups())
        start = h1 * 3600 + m1 * 60 + s1 + ms1 / 1000
        end = h2 * 3600 + m2 * 60 + s2 + ms2 / 1000
        text = " ".join(l.strip() for l in block[m.end():].strip().splitlines() if l.strip())
        text = re.sub(r"<[^>]+>", "", text)
        if text:
            cues.append((start, end, text))
    return cues
