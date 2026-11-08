"""作者：Wangyuan；日期：2026-10-29；职责：本地媒体检查、静音剪辑、脚本与转写编辑。"""
import tempfile,subprocess,os,hashlib
from pathlib import Path
from datetime import datetime
import autoclip
from script_segments import segment_script
from transcript import edit_transcript
from song_steps import default_steps
from progress import _elapsed_minutes

def local_file(value):
    path=Path(value).expanduser().resolve(strict=True)
    if not path.is_file():raise ValueError('需要本地文件')
    return path

def run(payload):
    if not isinstance(payload,dict):raise TypeError('输入须对象')
    action=payload.get('action','script')
    if action=='script':return {'segments':segment_script(payload.get('text','')),'song_steps':default_steps(False),'notice':'只分段与编排；未生成声音、人物或唱歌。'}
    if action=='transcript':return edit_transcript(payload.get('segments',[]),payload.get('edits',[]))
    if action=='quality':
        from quality import select_candidate_metrics
        return select_candidate_metrics(payload.get('candidates',[]))
    if action=='progress':return {'elapsed_minutes':_elapsed_minutes(payload['started'],datetime.fromisoformat(payload['now'])),'completed':sum(x.get('status')=='completed' for x in payload.get('jobs',[])),'notice':'仅调用方状态，不推断已发布或已收到。'}
    if action in {'inspect','cut'}:
        source=local_file(payload['input']);duration,audio,w,h=autoclip.probe(str(source))
        if duration<=0:raise ValueError('媒体无法读取')
        if action=='inspect':return {'duration':duration,'has_audio':audio,'width':w,'height':h,'sha256':hashlib.sha256(source.read_bytes()).hexdigest()}
        output=Path(payload['output']).expanduser().absolute()
        if output.exists() or output==source:raise ValueError('输出不能已存在')
        segments=payload.get('segments')
        if segments is None:segments=autoclip.compute_keep_segments(duration,autoclip.detect_silences(str(source)) if audio else [])
        if not segments or any(len(pair)!=2 or not 0<=pair[0]<pair[1]<=duration+0.01 for pair in segments):raise ValueError('裁剪区间无效')
        output.parent.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=output.parent) as d:
            stage=Path(d)/'render.mp4';autoclip.cut_video(str(source),str(stage),segments,audio)
            if not stage.exists():raise ValueError('媒体处理失败')
            # 同目录硬链接采用排他创建，避免覆盖并发创建的文件。
            os.link(stage,output)
        return {'output':str(output),'segments':segments,'duration':autoclip.probe(str(output))[0]}
    if action=='srt':return {'cues':autoclip.parse_srt(str(local_file(payload['input'])))}
    if action=='voice_activity':
        import numpy as np
        from voice_energy import _energy_timestamps
        values=np.asarray(payload.get('samples',[]),dtype=np.float32)
        if values.ndim!=1 or not np.isfinite(values).all():raise ValueError('音频须一维有限数')
        return {'segments':_energy_timestamps(values,float(payload.get('threshold',0.02))),'sample_rate':16000,'notice':'RMS能量活动，不是语音识别。'}
    raise ValueError('未知action')
