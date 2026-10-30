import json,sys,re,time; sys.path.insert(0,sys.argv[1]); from spark import spark,img; from sam import sam
from PIL import Image, ImageDraw, ImageFont
src=sys.argv[2]; out=src.replace(".jpg","_som.jpg")
text,dt=sam(src,"breaker"); print(f"SAM {dt:.1f}s")
boxes=[dict(kv.split("=") for kv in b.split(";")) for b in re.findall(r"<\|box;([^|]*)\|>",text)]
boxes=[{k:float(v) for k,v in b.items()} for b in boxes]
boxes.sort(key=lambda b:(b["x1"]))
im=Image.open(src).convert("RGB"); d=ImageDraw.Draw(im)
try: f=ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Bold.ttf",26)
except: f=ImageFont.load_default()
for i,b in enumerate(boxes,1):
    d.rectangle([b["x1"],b["y1"],b["x2"],b["y2"]],outline=(255,0,255),width=3)
    cx,cy=(b["x1"]+b["x2"])/2,b["y1"]+18
    d.rectangle([cx-17,cy-16,cx+17,cy+16],fill=(255,0,255)); d.text((cx,cy),str(i),fill="white",font=f,anchor="mm")
im.save(out,quality=90)
schema={"type":"object","additionalProperties":False,"required":["marks"],"properties":{"marks":{"type":"array","items":{
 "type":"object","additionalProperties":False,"required":["mark","is_breaker","label","state"],"properties":{
 "mark":{"type":"integer"},"is_breaker":{"type":"boolean"},"label":{"type":"string"},
 "state":{"type":"string","enum":["on","off","unclear","n/a"]}}}}}}
msgs=[{"role":"user","content":[img(out),{"type":"text","text":
 "Magenta numbered boxes mark candidate objects. For EVERY mark: is it a circuit breaker with a toggle lever (not a terminal block or a label)? If yes give its printed label and lever state."}]}]
for eff in sys.argv[3:]:
    r,dt=spark(msgs,schema,effort=eff); u=r["usage"]
    res=json.loads(r["choices"][0]["message"]["content"])["marks"]
    print(f"--- SoM effort={eff} {dt:.1f}s out_tokens={u['completion_tokens']}")
    for m in res:
        if m["is_breaker"]: b=boxes[m["mark"]-1]; print(f"   #{m['mark']:>2} {m['label']:>5} {m['state']:8} x={b['x1']:.0f}-{b['x2']:.0f}")
