from __future__ import annotations
from datetime import datetime,timedelta,timezone
TZ=timezone.utc

def _elapsed_minutes(started: str, now: datetime) -> float | None:
    """日志只有 HH:MM:SS，按当天补日期；跨零点时视为前一天，避免出现负的已用时长。"""
    try:
        stamp = datetime.strptime(started, "%H:%M:%S").replace(
            year=now.year, month=now.month, day=now.day, tzinfo=now.tzinfo)
    except ValueError:
        return None
    if stamp > now:  # 日志时间晚于当前时刻＝跨过午夜
        stamp -= timedelta(days=1)
    return round((now - stamp).total_seconds() / 60, 1)
