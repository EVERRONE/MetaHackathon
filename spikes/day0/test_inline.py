import json,sys,os,time,base64,urllib.request
KEY=os.environ["MODEL_API_KEY"]; som=sys.argv[1]; eff=sys.argv[2]
b64=base64.b64encode(open(som,"rb").read()).decode()
sysmsg=("You are Pip, a calm hands-on guide speaking out loud. Use short spoken sentences, one action at a time. "
 "The image has numbered magenta marks on candidate objects. When you refer to an object, put a cue tag immediately BEFORE the words that refer to it: "
 "[[outline:N]] to highlight mark N, [[arrow:N:up|down|left|right|cw|ccw]] to show a motion on mark N, [[clear]] to remove cues. Never mention mark numbers aloud.")
body={"model":"muse-spark-1.3","reasoning_effort":eff,"stream":True,
 "messages":[{"role":"system","content":sysmsg},
  {"role":"user","content":[{"type":"image_url","image_url":{"url":"data:image/jpeg;base64,"+b64}},{"type":"text","text":"Breaker 10F is off. Show me which one it is and how to switch it back on."}]}]}
req=urllib.request.Request("https://api.meta.ai/v1/chat/completions",data=json.dumps(body).encode(),headers={"Authorization":"Bearer "+KEY,"Content-Type":"application/json"})
t0=time.time(); out=""
with urllib.request.urlopen(req,timeout=120) as r:
  for line in r:
    line=line.decode().strip()
    if not line.startswith("data: ") or line=="data: [DONE]": continue
    d=json.loads(line[6:]); ch=d.get("choices") or [{}]; c=ch[0].get("delta",{}).get("content")
    if c: print(f"{time.time()-t0:5.2f}s {c!r}"); out+=c
print("\nFULL:",out)
