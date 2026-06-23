import { chromium } from "@playwright/test";
const [, , DIR, DOC] = process.argv;
const BASE="http://localhost:4000";
const b=await chromium.launch({headless:true,args:["--no-sandbox"]});
const p=await b.newPage({viewport:{width:1400,height:1000},deviceScaleFactor:2});
await p.goto(`${BASE}/workspace?path=${encodeURIComponent(DIR)}&document=${encodeURIComponent(DOC)}`,{waitUntil:"domcontentloaded",timeout:60000});
await p.waitForSelector("[data-role='office-wasm-canvas']",{timeout:60000}); await p.waitForTimeout(6000);
const out=await p.evaluate(()=>{
  const ed=window.__officeWasmEditor; if(!ed) return {error:"no editor"};
  let s=performance.now(); const raw=ed.api.getElements(); const tGet=performance.now()-s;
  s=performance.now(); const parsed=JSON.parse(raw); const tParse=performance.now()-s;
  const list=Array.isArray(parsed)?parsed:(parsed&&parsed.elements)||[];
  s=performance.now(); const norm=list.map(e=>ed.normElement(e)).filter(Boolean); const tNorm=performance.now()-s;
  // isolate defineProperty cost: re-run map without it
  s=performance.now(); for(const e of list){ if(e&&e.ref){ const o={ref:String(e.ref)}; o.raw=e; } } const tPlain=performance.now()-s;
  return {count:list.length, rawBytes: typeof raw==="string"?raw.length:null, tGet:+tGet.toFixed(1), tParse:+tParse.toFixed(1), tNorm:+tNorm.toFixed(1), tPlainAssign:+tPlain.toFixed(1)};
});
console.log(JSON.stringify(out));
await b.close();
