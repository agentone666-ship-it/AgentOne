"""Exercise the shipped classifier on feature categories or wording probes, never private audio."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT=Path(__file__).resolve().parents[2]
CATEGORIES=[
    ("sustained", "持续检测到明显声音，声音已稳定持续 3 秒", "record"),
    ("quiet", "环境安静，没有明显的连续声音", "wait"),
    ("unknown", "输入状态未知，没有可靠的声音证据", "wait"),
    ("transient", "仅有短促声音，没有持续活动", "wait"),
]
PROBES=[
    ("quiet_minute","电脑和麦克风都没有声音，安静已经持续一分钟","wait"),
    ("coworker_speech","同事刚开始说话，麦克风持续收到声音","record"),
    ("video","电脑正在播放一段视频，能听到声音","record"),
    ("mic_disconnected","麦克风断开，无法确定是否安静","wait"),
    ("quiet_30","静音持续30秒，电脑和麦克风都有正常采样","wait"),
    ("pause_2","一段谈话中的短暂停顿，安静2秒","wait"),
    ("system_lost","系统声音服务中断，声音状态未知","wait"),
    ("pause_5","刚刚播放完音乐，安静了5秒","wait"),
]
probe="--holdout" in sys.argv
python=Path.home()/"Library/Application Support/AgentOne/Laya/.venv/bin/python"
env={**os.environ,"HF_HOME":str(python.parents[2]/"cache"),"HF_HUB_OFFLINE":"1","USE_TF":"0"}
proc=subprocess.Popen([str(python),"-u",str(ROOT/"tools/laya-decision/worker.py")],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,env=env)
assert json.loads(proc.stdout.readline())["ready"]
rows=[]
try:
    for name,description,expected in PROBES if probe else CATEGORIES:
        before=time.perf_counter()
        proc.stdin.write(json.dumps({"id":name,"state":{"声音状态":description}},ensure_ascii=False)+"\n");proc.stdin.flush()
        answer=json.loads(proc.stdout.readline())
        rows.append({"case":name,"expected":expected,**answer,"latency_ms":round((time.perf_counter()-before)*1000,1)})
finally:
    proc.stdin.close();proc.wait(timeout=10)
report={"kind":"wording_probe_not_audio_accuracy" if probe else "production_feature_category_smoke_not_audio_accuracy","policy":"0.2.8","model":"convaiinnovations/laya/multilingual","revision":"7b928d828b7b0e022f929d9bd2e44165aa270148","runtime":"laya==0.4.12","correct":sum(r.get("choice")==r["expected"] for r in rows),"total":len(rows),"rows":rows}
result=ROOT/("build/benchmarks/capture-start-028-wording.json" if probe else "build/benchmarks/capture-start-028.json");result.parent.mkdir(parents=True,exist_ok=True);result.write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n")
print(json.dumps(report,ensure_ascii=False,indent=2))
