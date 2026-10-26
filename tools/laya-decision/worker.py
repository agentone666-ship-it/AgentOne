"""Local typed-decision worker. No microphone, agent tools, network server or user text logs."""
import json
import os
import sys

os.environ.setdefault("USE_TF", "0")
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

QUESTIONS = {"capture": {"type": "choice", "instructions": "当前是否有明显且连续的声音？", "criteria": {
    "A": "已经持续检测到明显声音，可以开始录音",
    "B": "没有持续的明显声音，静音或者输入未知，继续听候"}}}


def main():
    import contextlib
    # Libraries may print diagnostics; stdout is a strict JSONL protocol.
    with contextlib.redirect_stdout(sys.stderr):
        import laya
        agent = laya.load("convaiinnovations/laya", subfolder="multilingual", device="cpu", revision="7b928d828b7b0e022f929d9bd2e44165aa270148")
    print(json.dumps({"ready": True, "model": "convaiinnovations/laya/multilingual", "runtime": laya.__version__}), flush=True)
    for line in sys.stdin:
        try:
            request = json.loads(line)
            with contextlib.redirect_stdout(sys.stderr):
                result = agent.predict(request["state"]["声音状态"], QUESTIONS)
            answer = result["answers"]["capture"]
            response = {"id": request["id"], "choice": {"A": "record", "B": "wait"}[answer["choice"]], "confidence": float(answer["answer_confidence"]), "entropy_confidence": float(answer["confidence"])}
        except Exception:
            response = {"id": request.get("id") if isinstance(locals().get("request"), dict) else None, "error": "inference_failed"}
        print(json.dumps(response, ensure_ascii=False, allow_nan=False), flush=True)


if __name__ == "__main__":
    main()
