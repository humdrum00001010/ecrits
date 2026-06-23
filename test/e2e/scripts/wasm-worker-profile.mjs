import { chromium } from "@playwright/test";
const [, , DIR, DOC] = process.argv;
const BASE="http://localhost:4000";
const b=await chromium.launch({headless:true,args:["--no-sandbox"]});
const p=await b.newPage({viewport:{width:1400,height:1000},deviceScaleFactor:2});
await p.goto(`${BASE}/workspace?path=${encodeURIComponent(DIR)}&document=${encodeURIComponent(DOC)}`,{waitUntil:"domcontentloaded",timeout:60000});
await p.waitForSelector("[data-role='office-wasm-canvas']",{timeout:60000}); await p.waitForTimeout(6000);
const workers=p.workers();
console.log("workers:", workers.length, workers.map(w=>w.url().split("/").pop()).join(","));
// attach Profiler to every worker
const sessions=[];
for(const w of workers){ try{ const s=await p.context().newCDPSession(w); await s.send("Profiler.enable"); await s.send("Profiler.setSamplingInterval",{interval:100}); await s.send("Profiler.start"); sessions.push({w,s}); }catch(e){ console.log("attach fail", e.message.slice(0,60)); } }
await p.evaluate(()=>{ const ed=window.__officeWasmEditor; ed.rendered.clear(); ed.renderPage(0,{force:true}); });
for(const {w,s} of sessions){
  try{
    const {profile}=await s.send("Profiler.stop");
    const m=new Map(); let tot=0, wasm=0;
    for(const n of profile.nodes){ const h=n.hitCount||0; if(!h)continue; const f=n.callFrame||{}; const isW=/wasm/.test(f.url||""); const k=(f.functionName||"(anon)")+(isW?" «wasm»":""); m.set(k,(m.get(k)||0)+h); tot+=h; if(isW)wasm+=h; }
    if(tot>50){ console.log(`\n[worker ${w.url().split("/").pop()}] samples=${tot} wasm%=${(100*wasm/tot).toFixed(0)} -> ${(tot*0.1).toFixed(0)}ms`);
      console.log([...m.entries()].sort((a,b)=>b[1]-a[1]).slice(0,8).map(([k,h])=>`  ${(h*0.1).toFixed(1)}ms ${k}`).join("\n")); }
  }catch(_){}
}
await b.close();
