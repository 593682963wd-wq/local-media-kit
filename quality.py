from __future__ import annotations
from typing import Any,Iterable

QUALITY_THRESHOLDS: dict[str, float] = {
    "detection_rate_pct": 95.0,
    "identity_cosine_p10": 0.45,
    "identity_cosine_median": 0.55,
    "identity_cosine_std_max": 0.08,
    "identity_jump_p95_max": 0.12,
    "sharp_p10": 25.0,
    "sharp_median": 45.0,
    "sharp_median_max": 1200.0,
    "sharp_cv_pct_max": 85.0,
    "luma_jump_p95_max": 10.0,
    "luma_jump_max": 35.0,
    "adjacent_delta_p95_max": 42.0,
}

def evaluate_metric_gate(metrics: dict[str, float | int]) -> list[str]:
    t = QUALITY_THRESHOLDS
    checks: tuple[tuple[bool, str], ...] = (
        (float(metrics["detection_rate_pct"]) >= t["detection_rate_pct"], "人脸检测覆盖率不足"),
        (float(metrics["identity_cosine_p10"]) >= t["identity_cosine_p10"], "身份相似度低分位不足"),
        (float(metrics["identity_cosine_median"]) >= t["identity_cosine_median"], "身份相似度中位数不足"),
        (float(metrics["identity_cosine_std"]) <= t["identity_cosine_std_max"], "身份波动过大"),
        (float(metrics["identity_jump_p95"]) <= t["identity_jump_p95_max"], "相邻帧身份跳变过大"),
        (float(metrics["sharp_p10"]) >= t["sharp_p10"], "低分位脸部清晰度不足"),
        (float(metrics["sharp_median"]) >= t["sharp_median"], "脸部清晰度不足"),
        (float(metrics["sharp_median"]) <= t["sharp_median_max"], "脸部锐化异常，可能出现假脸边缘"),
        (float(metrics["sharp_cv_pct"]) <= t["sharp_cv_pct_max"], "脸部清晰度波动过大"),
        (float(metrics["luma_jump_p95"]) <= t["luma_jump_p95_max"], "亮度闪变 P95 过高"),
        (float(metrics["luma_jump_max"]) <= t["luma_jump_max"], "最大亮度闪变过高"),
        (float(metrics["adjacent_delta_p95"]) <= t["adjacent_delta_p95_max"], "脸部相邻帧变化异常"),
    )
    return [label for passed, label in checks if not passed]

def candidate_score(metrics: dict[str, float | int]) -> float:
    return round(
        float(metrics["identity_cosine_p10"]) * 45
        + float(metrics["identity_cosine_median"]) * 25
        + min(float(metrics["sharp_p10"]) / 120.0, 1.0) * 12
        + min(float(metrics["sharp_median"]) / 180.0, 1.0) * 8
        + max(0.0, 1.0 - float(metrics["identity_cosine_std"]) / QUALITY_THRESHOLDS["identity_cosine_std_max"]) * 5
        + max(0.0, 1.0 - float(metrics["luma_jump_p95"]) / QUALITY_THRESHOLDS["luma_jump_p95_max"]) * 5,
        3,
    )

def select_candidate_metrics(candidates: Iterable[dict[str, Any]]) -> dict[str, Any]:
    evaluated: list[dict[str, Any]] = []
    for candidate in candidates:
        item = dict(candidate)
        failures = evaluate_metric_gate(item["metrics"])
        item["failures"] = failures
        item["passed"] = not failures
        item["score"] = candidate_score(item["metrics"]) if not failures else None
        evaluated.append(item)
    passed = [item for item in evaluated if item["passed"]]
    if not passed:
        return {"selected": None, "candidates": evaluated, "reason": "no_candidate_passed"}
    selected = max(passed, key=lambda item: float(item["score"]))
    return {"selected": selected, "candidates": evaluated, "reason": "quality_gate_passed"}
