import json,sys; sys.path.insert(0,sys.argv[1]); from spark import spark,img
schema={"type":"object","additionalProperties":False,"required":["devices"],"properties":{"devices":{"type":"array","items":{
 "type":"object","additionalProperties":False,"required":["label","state","box","confidence"],"properties":{
  "label":{"type":"string"},"state":{"type":"string","enum":["on","off","tripped","unclear"]},
  "box":{"type":"array","items":{"type":"integer"}},"confidence":{"type":"number"}}}}}}
msgs=[{"role":"user","content":[img(sys.argv[2]),{"type":"text","text":
 "List every circuit breaker (the modular devices with a toggle lever) from left to right. For each give the printed label below it, the lever state, and its bounding box [x1,y1,x2,y2] on the 0-1000 grid."}]}]
for eff in sys.argv[3:]:
    d,dt=spark(msgs,schema,effort=eff)
    c=d["choices"][0]["message"]["content"]; u=d["usage"]
    print(f"--- effort={eff} {dt:.1f}s tokens in={u['prompt_tokens']} out={u['completion_tokens']}")
    for x in json.loads(c)["devices"]: print("  ",x["label"],x["state"],x["box"],x["confidence"])
