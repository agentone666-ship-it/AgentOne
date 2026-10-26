"""Run the shipped JSONL worker on fixed descriptive states, never private audio."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT=Path(__file__).resolve().parents[2]
TUNING=[
    ("active_both", "电脑声音和麦克风均已接入，当前有声音活动", "record"),
    ("active_mic", "麦克风正在接收到持续说话的声音，电脑没有播放声音", "record"),
    ("active_system", "电脑正在播放声音，麦克风安静", "record"),
    ("quiet_20", "电脑和麦克风均已接入，持续安静，已持续 20 秒", "wait"),
    ("quiet_60", "电脑和麦克风均已接入，持续安静，已持续 60 秒", "wait"),
    ("unknown", "输入尚未完全就绪，声音情况未知", "record"),
]
HOLDOUT=[
    ("quiet_minute","电脑和麦克风都没有声音，安静已经持续一分钟","wait",60,True),
    ("coworker_speech","同事刚开始说话，麦克风持续收到声音","record",0,True),
    ("video","电脑正在播放一段视频，能听到声音","record",0,True),
    ("mic_disconnected","麦克风断开，无法确定是否安静","record",60,False),
    ("quiet_30","静音持续30秒，电脑和麦克风都有正常采样","wait",30,True),
    ("pause_2","一段谈话中的短暂停顿，安静2秒","record",2,True),
    ("system_lost","系统声音服务中断，声音状态未知","record",60,False),
    ("pause_5","刚刚播放完音乐，安静了5秒","record",5,True),
]
holdout="--holdout" in sys.argv
STATES=HOLDOUT if holdout else [(name,state,expected,60 if expected=="wait" else 0,name!="unknown") for name,state,expected in TUNING]
python=Path.home()/"Library/Application Support/AgentOne/Laya/.venv/bin/python"
env={**os.environ,"HF_HOME":str(python.parents[2]/"cache"),"HF_HUB_OFFLINE":"1","USE_TF":"0"}
proc=subprocess.Popen([str(python),"-u",str(ROOT/"tools/laya-decision/worker.py")],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,env=env)
assert json.loads(proc.stdout.readline())["ready"]
rows=[]
try:
    for current in (["正在保存混合录音"] if holdout else ["正在保存混合录音","听候新声音，内存有 10 秒预录"]):
        for name,description,expected,quiet,ready in STATES:
            state={"声音状态":description,"当前状态":current,"用户偏好":"尽可能保留信息；声音或状态不确定时应保存"}
            before=time.perf_counter()
            proc.stdin.write(json.dumps({"id":name,"state":state},ensure_ascii=False)+"\n");proc.stdin.flush()
            answer=json.loads(proc.stdout.readline())
            controlled="wait" if answer.get("choice")=="wait" and answer.get("confidence",0)>=0.75 and quiet>=15 and ready else "record"
            rows.append({"controlled":controlled,"case":name,"current":current,"expected":expected,**answer,"latency_ms":round((time.perf_counter()-before)*1000,1)})
finally:
    proc.stdin.close();proc.wait(timeout=10)
report={"kind":"synthetic_descriptive_state_not_audio_accuracy","model":"convaiinnovations/laya/multilingual","revision":"7b928d828b7b0e022f929d9bd2e44165aa270148","runtime":"laya==0.4.12","holdout":holdout,"controlled_correct":sum(r["controlled"]==r["expected"] for r in rows),"correct":sum(r.get("choice")==r["expected"] for r in rows),"total":len(rows),"rows":rows}
result=ROOT/("build/benchmarks/capture-laya-holdout.json" if holdout else "build/benchmarks/capture-laya.json");result.parent.mkdir(parents=True,exist_ok=True);result.write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n")
print(json.dumps(report,ensure_ascii=False,indent=2))
