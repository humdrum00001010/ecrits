import { chromium } from "@playwright/test";
const [, , DIR, DOC] = process.argv;
const BASE="http://localhost:4000";
const b=await chromium.launch({headless:true,args:["--no-sandbox"]});
const p=await b.newPage({viewport:{width:1400,height:1000},deviceScaleFactor:2});
await p.goto(`${BASE}/workspace?path=${encodeURIComponent(DIR)}&document=${encodeURIComponent(DOC)}`,{waitUntil:"domcontentloaded",timeout:60000});
await p.waitForSelector("[data-role='office-wasm-canvas']",{timeout:60000}); await p.waitForTimeout(6000);
const c=await p.context().newCDPSession(p);
await c.send("Profiler.enable");
await c.send("Profiler.setSamplingInterval",{interval:100});
await c.send("Profiler.start");
await p.evaluate(()=>{ const ed=window.__officeWasmEditor; ed.rendered.clear(); ed.renderPage(0,{force:true}); });   // paintTile
await p.evaluate(()=>{ const ed=window.__officeWasmEditor; ed._elementsCache=null; ed.officeElements(); });            // getElements
const {profile}=await c.send("Profiler.stop");
// aggregate self-time per node (hitCount * interval µs)
const byKey=new Map();
let total=0, wasmTotal=0;
for(const n of profile.nodes){
  const h=n.hitCount||0; if(!h) continue;
  const f=n.callFrame||{}; const url=f.url||""; const isWasm=/wasm/.test(url);
  const name=(f.functionName||"(anon)")+(isWasm?" «wasm»":"");
  byKey.set(name,(byKey.get(name)||0)+h); total+=h; if(isWasm) wasmTotal+=h;
}
const us=profile.endTime? null:null;
const top=[...byKey.entries()].sort((a,b)=>b[1]-a[1]).slice(0,18)
  .map(([n,h])=>`${(h*0.1).toFixed(1)}ms  ${n}`);
console.log(`samples-total=${total}  wasm%=${(100*wasmTotal/total).toFixed(0)}  namedWasm=${[...byKey.keys()].some(k=>/«wasm»/.test(k)&&!/^(\(anon\)|wasm-function|\$func)/.test(k))}`);
console.log(top.join("\n"));
await b.close();
