import json, sys, time, base64, os, re, urllib.request
KEY = os.environ["MODEL_API_KEY"]
def sam(img_path, prompt, extra_content=None):
    b64 = base64.b64encode(open(img_path,"rb").read()).decode()
    content = [{"type":"input_text","text":prompt},{"type":"input_image","image_url":"data:image/jpeg;base64,"+b64}]
    body = {"model":"sam-3.1","stream":True,"metadata":{"include_confidence":"true","mask_encoding":"one_bit"},
            "input":[{"type":"message","role":"user","content":content}]}
    req = urllib.request.Request("https://api.meta.ai/v1/responses", data=json.dumps(body).encode(),
        headers={"Authorization":"Bearer "+KEY,"Content-Type":"application/json"})
    t=time.time(); text=""
    with urllib.request.urlopen(req, timeout=60) as r:
        for line in r:
            line=line.decode().strip()
            if line.startswith("data: {"):
                d=json.loads(line[6:])
                if d.get("type")=="response.output_text.done": text=d["text"]
    return text, time.time()-t
if __name__=="__main__":
    img=sys.argv[1]
    for p in sys.argv[2:]:
        text,dt=sam(img,p)
        boxes=re.findall(r"<\|box;([^|]*)\|>",text)
        print(f"{p!r:28} n={len(boxes):<3} {dt:.1f}s")
        for b in boxes[:20]: print("    ",b)
