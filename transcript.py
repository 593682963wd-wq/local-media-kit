"""作者：Wangyuan；日期：2026-10-29；职责：转写草稿分段、纠错、合并与导出；无语音识别。"""
from copy import deepcopy

def edit_transcript(segments,edits):
    rows=deepcopy(segments)
    for row in rows:
        if float(row['start'])<0 or float(row['end'])<=float(row['start']):raise ValueError('分段时间无效')
        row['text']=str(row['text']);row['reviewed']=bool(row.get('reviewed',False))
    audit=[]
    for edit in edits:
        idx=int(edit['index'])
        if not 0<=idx<len(rows):raise ValueError('分段索引无效')
        row=rows[idx];kind=edit['type']
        if kind=='replace':row['text']=str(edit['text']);row['reviewed']=False
        elif kind=='review':row['reviewed']=True
        elif kind=='split':
            at=float(edit['at']);left,right=edit['texts']
            if not row['start']<at<row['end']:raise ValueError('拆分点无效')
            rows[idx:idx+1]=[{'start':row['start'],'end':at,'text':left,'reviewed':False},{'start':at,'end':row['end'],'text':right,'reviewed':False}]
        elif kind=='merge':
            if idx+1>=len(rows):raise ValueError('无下一段')
            nxt=rows.pop(idx+1);row['end']=nxt['end'];row['text']+=' '+nxt['text'];row['reviewed']=False
        else:raise ValueError('编辑类型无效')
        audit.append({'type':kind,'index':idx})
    def ts(t):
        ms=round(float(t)*1000);return f'{ms//3600000:02}:{ms//60000%60:02}:{ms//1000%60:02},{ms%1000:03}'
    srt='\n\n'.join(f"{i+1}\n{ts(row['start'])} --> {ts(row['end'])}\n{row['text']}" for i,row in enumerate(rows))
    return {'segments':rows,'audit':audit,'all_reviewed':bool(rows) and all(row['reviewed'] for row in rows),'srt':srt}
