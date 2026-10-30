"""Local speaker verification. Audio/profile never leaves this process/device."""
import os
os.umask(0o077)
import json,sys,pathlib,wave,hashlib,math
import numpy as np
import sherpa_onnx

def normalize(v):
 v=np.asarray(v,dtype=np.float32);n=float(np.linalg.norm(v))
 if not np.all(np.isfinite(v)) or n<1e-8:raise ValueError('Invalid embedding')
 return v/n

from voiceprint_policy import verdict

def process(job):
 root=pathlib.Path(job['models']);manifest=json.loads((root/'models.json').read_text())
 for name in ['speaker.onnx','vad.onnx']:
  if hashlib.sha256((root/name).read_bytes()).hexdigest()!=manifest[name]['sha256']:raise ValueError('Model integrity mismatch')
 model_hash=manifest['speaker.onnx']['sha256']
 with wave.open(job['audio'],'rb') as f:
  if f.getnchannels()!=1 or f.getsampwidth()!=2 or f.getframerate()!=16000:raise ValueError('Expected mono 16 kHz PCM16 WAV')
  audio=np.frombuffer(f.readframes(f.getnframes()),dtype='<i2').astype(np.float32)/32768
 if len(audio)>16000*125 or len(audio)==0:raise ValueError('Invalid bounded source duration')
 config=sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(root/'speaker.onnx'),num_threads=1,provider='cpu')
 extractor=sherpa_onnx.SpeakerEmbeddingExtractor(config)
 vc=sherpa_onnx.VadModelConfig();vc.silero_vad.model=str(root/'vad.onnx');vc.sample_rate=16000
 vad=sherpa_onnx.VoiceActivityDetector(vc,buffer_size_in_seconds=130)
 for offset in range(0,len(audio),512):vad.accept_waveform(np.pad(audio[offset:offset+512],(0,max(0,512-len(audio[offset:offset+512])))))
 vad.flush();ranges=[]
 while not vad.empty():
  ranges.append((vad.front.start,min(len(audio),vad.front.start+len(vad.front.samples))));vad.pop()
 speech=sum(b-a for a,b in ranges)/16000;vectors=[]
 for start in range(0,max(0,len(audio)-48000+1),24000):
  end=start+48000;voiced=sum(max(0,min(end,b)-max(start,a)) for a,b in ranges)/16000
  if voiced<2.4:continue
  piece=audio[start:end]
  if np.mean(np.abs(piece)>=.99)>.02:continue
  stream=extractor.create_stream();stream.accept_waveform(sample_rate=16000,waveform=piece);stream.input_finished()
  if extractor.is_ready(stream):vectors.append((start//16,end//16,normalize(extractor.compute(stream))))
 if job['mode']=='enroll':
  if speech<12 or len(vectors)<4:raise ValueError('需要至少12秒清晰人声；请靠近麦克风独自朗读，关闭播放声音')
  mean=normalize(np.mean([v for _,_,v in vectors],axis=0))
  if min(float(np.dot(v,mean)) for _,_,v in vectors)<.5:raise ValueError('录入声音不够一致；请确保只有本人说话后重录')
  return {'model_hash':model_hash,'embedding':mean.tolist(),'speech_seconds':speech,'windows':len(vectors),'version':1}
 profile=json.loads(pathlib.Path(job['profile']).read_text())
 if profile['model_hash']!=model_hash:raise ValueError('声纹模型已改变，请重新录入')
 ref=normalize(profile['embedding']);scores=[{'start_ms':a,'end_ms':b,'score':float(np.dot(v,ref))}for a,b,v in vectors]
 return {'profile_id':profile.get('profile_id'),'status':verdict(scores,speech),'score':max((x['score']for x in scores),default=None),'intervals':[x for x in scores if x['score']>=.65],'speech_seconds':speech,'windows':len(scores),'model_hash':model_hash}

if __name__=='__main__':
 try:print(json.dumps(process(json.loads(pathlib.Path(sys.argv[1]).read_text())),ensure_ascii=False,allow_nan=False))
 except Exception as e:print(json.dumps({'error':str(e)[:300]},ensure_ascii=False));sys.exit(1)
