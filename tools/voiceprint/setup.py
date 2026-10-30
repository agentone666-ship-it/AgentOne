"""Explicit local install only; never reads or uploads audio."""
import pathlib,subprocess,sys,urllib.request,hashlib,os,json
os.umask(0o077)
if sys.version_info<(3,10):raise SystemExit("Python 3.10 or newer is required")
root=pathlib.Path(sys.argv[1]);root.mkdir(parents=True,exist_ok=True)
subprocess.run([sys.executable,'-m','venv',str(root/'runtime')],check=True)
python=root/'runtime/bin/python'
subprocess.run([str(python),'-m','pip','install','--disable-pip-version-check','sherpa-onnx==2.0.1','numpy==2.2.6'],check=True)
models={
 'speaker.onnx':'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx',
 'vad.onnx':'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx'}
manifest={}
for name,url in models.items():
 target=root/name;temp=root/(name+'.download')
 urllib.request.urlretrieve(url,temp);temp.chmod(0o600);temp.replace(target)
 manifest[name]={'url':url,'sha256':hashlib.sha256(target.read_bytes()).hexdigest()}
(root/'models.json').write_text(json.dumps(manifest));print('Local voiceprint components installed.')
