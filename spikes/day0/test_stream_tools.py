import json,sys,os,time,base64,urllib.request
KEY=os.environ["MODEL_API_KEY"]; som=sys.argv[1]; eff=sys.argv[2]
tools=[{"type":"function","function":{"name":"point","description":"Draw an annotation on a numbered mark in the current image. Call it right before you say the words that refer to that object.",
 "parameters":{"type":"object","additionalProperties":False,"required":["mark","style"],"properties":{
  "mark":{"type":"integer"},"style":{"type":"string","enum":["outline","arrow_down","arrow_up","circle"]}}}}}]
b64=base64.b64encode(open(som,"rb").read()).decode()
body={"model":"muse-spark-1.3","reasoning_effort":eff,"stream":True,"tools":tools,"parallel_tool_calls":True,
 "messages":[{"role":"system","content":"You are Pip, a calm hands-on guide. Speak in short spoken sentences. Whenever you refer to an object, call point() at that moment, then continue talking."},
  {"role":"user","content":[{"type":"image_url","image_url":{"url":"data:image/jpeg;base64,"+b64}},{"type":"text","text":"Breaker 10F is off. Show me which one it is and how to switch it back on."}]}]}
req=urllib.request.Request("https://api.meta.ai/v1/chat/completions",data=json.dumps(body).encode(),headers={"Authorization":"Bearer "+KEY,"Content-Type":"application/json"})
t0=time.time(); first=None
with urllib.request.urlopen(req,timeout=120) as r:
  for line in r:
    line=line.decode().strip()
    if not line.startswith("data: ") or line=="data: [DONE]": continue
    d=json.loads(line[6:]); ch=d.get("choices") or [{}]; delta=ch[0].get("delta",{})
    t=time.time()-t0
    if delta.get("content"):
        first=first or t; print(f"{t:5.2f}s TEXT {delta['content']!r}")
    for tc in delta.get("tool_calls") or []:
        first=first or t; print(f"{t:5.2f}s TOOL {json.dumps(tc)}")
    if ch[0].get("finish_reason"): print(f"{t:5.2f}s FINISH {ch[0]['finish_reason']}")
print("first output at", first)
