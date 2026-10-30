import json,sys,os,time,uuid,urllib.request
KEY=os.environ["MODEL_API_KEY"]
def transcribe(path, langs=None):
    b=uuid.uuid4().hex; req_json={"model":"muse-voice-transcribe-1.0","audioEncoding":"WAV","mode":"PUSH_TO_TALK"}
    if langs: req_json["languages"]=langs
    parts=[(f'--{b}\r\nContent-Disposition: form-data; name="request"\r\nContent-Type: application/json\r\n\r\n'+json.dumps(req_json)+'\r\n').encode(),
           (f'--{b}\r\nContent-Disposition: form-data; name="audio"; filename="a.wav"\r\nContent-Type: audio/wav\r\n\r\n').encode()+open(path,"rb").read()+b'\r\n',
           f'--{b}--\r\n'.encode()]
    req=urllib.request.Request("https://api.meta.ai/v1/asr/transcribe",data=b"".join(parts),
        headers={"Authorization":"Bearer "+KEY,"Content-Type":f"multipart/form-data; boundary={b}","Accept":"application/json"})
    t=time.time()
    try:
        with urllib.request.urlopen(req,timeout=60) as r: return r.read().decode(), time.time()-t
    except urllib.error.HTTPError as e: return f"HTTP {e.code}: {e.read().decode()[:600]}", time.time()-t
for p in sys.argv[1:]:
    out,dt=transcribe(p); print(f"{os.path.basename(p)} {dt:.1f}s -> {out[:600]}")
