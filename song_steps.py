from __future__ import annotations
from typing import Any
from datetime import datetime,timezone
def now_cst():return datetime.now(timezone.utc).isoformat()

def default_steps(profile_ready: bool) -> list[dict[str, Any]]:
    base_status = "ready" if profile_ready else "blocked"
    base_message = "已关联音色档案。" if profile_ready else "请先选择音色档案。"
    return [
        {"id": "voice_profile", "name": "音色档案", "status": "done" if profile_ready else "blocked", "message": base_message, "artifacts": [], "updated_at": now_cst()},
        {"id": "lyrics", "name": "歌词与风格", "status": "ready", "message": "可先生成草稿，再手工微调。", "artifacts": [], "updated_at": now_cst()},
        {"id": "song_draft", "name": "AI 歌曲草稿", "status": base_status, "message": "可选适配器未包含： ACE-Step / YuE 生成带人声歌曲。", "artifacts": [], "updated_at": now_cst()},
        {"id": "separate", "name": "可选分离人声伴奏", "status": "pending", "message": "第一版可跳过；需要更高质量时再用 Demucs / UVR 分轨。", "artifacts": [], "updated_at": now_cst()},
        {"id": "convert_voice", "name": "转换为指定音色", "status": "pending", "message": "使用 Seed-VC 零训练把 AI 原唱转换为指定参考音色。", "artifacts": [], "updated_at": now_cst()},
        {"id": "mix_master", "name": "混音导出", "status": "pending", "message": "导出最终 WAV/FLAC。", "artifacts": [], "updated_at": now_cst()},
        {"id": "release_pack", "name": "发布留痕", "status": "pending", "message": "整理歌词、提示词、授权声明、AI 合成说明。", "artifacts": [], "updated_at": now_cst()},
    ]
