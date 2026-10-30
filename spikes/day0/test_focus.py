import json,sys; sys.path.insert(0,sys.argv[1]); from spark import spark,img
som=sys.argv[2]
schema={"type":"object","additionalProperties":False,"required":["mark","state","confidence","reason"],"properties":{
 "mark":{"type":"integer"},"state":{"type":"string","enum":["on","off","unclear"]},"confidence":{"type":"number"},"reason":{"type":"string"}}}
for target,eff in [("10F","minimal"),("10F","low"),("4F","minimal"),("13F2","minimal")]:
    msgs=[{"role":"user","content":[img(som),{"type":"text","text":
     f"Magenta numbered boxes mark candidate objects. Which mark is the circuit breaker labelled {target}, and is its lever on or off? Answer 0 if no mark fits. Keep reason under 15 words."}]}]
    r,dt=spark(msgs,schema,effort=eff,max_tokens=3000)
    print(f"{target:5} effort={eff:8} {dt:5.1f}s out={r['usage']['completion_tokens']:5} -> {r['choices'][0]['message']['content']}")
