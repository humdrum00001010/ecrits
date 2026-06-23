import { chromium } from "@playwright/test";
const [, , DIR, DOC] = process.argv;
const BASE="http://localhost:4000";
const b=await chromium.launch({headless:true,args:["--no-sandbox"]});
const p=await b.newPage({viewport:{width:1400,height:1000},deviceScaleFactor:2});
await p.goto(`${BASE}/workspace?path=${encodeURIComponent(DIR)}&document=${encodeURIComponent(DOC)}`,{waitUntil:"domcontentloaded",timeout:60000});
await p.waitForSelector("[data-role='office-wasm-canvas']",{timeout:60000}); await p.waitForTimeout(6000);
const out=await p.evaluate(async ()=>{
  const ed=window.__officeWasmEditor; if(!ed) return {error:"no editor"};
  let paints=0; const orig=ed.renderPage.bind(ed);
  ed.renderPage=(i,o)=>{ paints++; return orig(i,o); };
  const s=performance.now();
  for(let k=0;k<5;k++) ed.renderAfterInput();           // simulate a 5-key burst in one task
  const queueMs=performance.now()-s;                     // sync cost now (should be ~0 = just queueing)
  await new Promise(res=>{const t=()=> (ed.renderQueue.size||ed.renderQueueTimer)?setTimeout(t,10):res(); setTimeout(t,10);});
  ed.renderPage=orig;
  const c=document.querySelector("[data-role='office-wasm-canvas']");
  return { burstOf5_paints:paints, syncQueueMs:+queueMs.toFixed(1), canvasOk: !!(c&&c.width>1) };
});
console.log(DOC, JSON.stringify(out));
await b.close();
