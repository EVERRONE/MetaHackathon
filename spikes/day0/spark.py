import json, sys, time, base64, os, urllib.request
KEY=os.environ["MODEL_API_KEY"]
def spark(messages, schema=None, effort="low", max_tokens=4000):
    body={"model":"muse-spark-1.3","reasoning_effort":effort,"messages":messages,"max_completion_tokens":max_tokens}
    if schema: body["response_format"]={"type":"json_schema","json_schema":{"name":"out","strict":True,"schema":schema}}
    req=urllib.request.Request("https://api.meta.ai/v1/chat/completions",data=json.dumps(body).encode(),
        headers={"Authorization":"Bearer "+KEY,"Content-Type":"application/json"})
    t=time.time()
    try:
        with urllib.request.urlopen(req,timeout=120) as r: d=json.load(r)
    except urllib.error.HTTPError as e:
        print("HTTP",e.code,e.read().decode()[:800]); raise
    return d, time.time()-t
def img(path):
    return {"type":"image_url","image_url":{"url":"data:image/jpeg;base64,"+base64.b64encode(open(path,"rb").read()).decode()}}
