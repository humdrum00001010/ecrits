import { chromium } from "@playwright/test";
const [, , DIR, DOC] = process.argv;
const BASE="http://localhost:4000";
const b=await chromium.launch({headless:true,args:["--no-sandbox"]});
const p=await b.newPage({viewport:{width:1200,height:1000},deviceScaleFactor:Number(process.env.DPR)||1});
const errs=[]; p.on("console",m=>{const t=m.text(); if(/wasm-hwp|renderPage|fail|error|RangeError|memory|abort/i.test(t)) errs.push(m.type()+":"+t.slice(0,140));});
p.on("pageerror",e=>errs.push("PAGEERR:"+e.message.slice(0,140)));
await p.goto(`${BASE}/workspace?path=${encodeURIComponent(DIR)}&document=${encodeURIComponent(DOC)}`,{waitUntil:"domcontentloaded",timeout:60000});
await p.waitForSelector("[data-role='ehwp-canvas']",{timeout:60000}).catch(()=>{});
await p.waitForTimeout(7000);
const out=await p.evaluate(async ()=>{
  const sections=[...document.querySelectorAll("[data-role='local-hwp-page']")];
  const pages=[];
  for(let i=0;i<Math.min(sections.length,14);i++){
    sections[i].scrollIntoView({block:"center"}); await new Promise(r=>setTimeout(r,400));
    const c=sections[i].querySelector("[data-role='ehwp-canvas']");
    let nw=0,n=0,w=0,h=0;
    if(c&&c.width>1){ w=c.width;h=c.height; const d=c.getContext("2d").getImageData(0,0,w,h).data;
      for(let k=0;k<d.length;k+=64){ n++; if(d[k]<245||d[k+1]<245||d[k+2]<245) nw++; } }  // stride sample whole canvas
    pages.push({i,w,h,pct:+(100*nw/(n||1)).toFixed(1)});
  }
  return {count:sections.length, pages};
});
console.log("DPR="+(process.env.DPR||1), "pageCount="+out.count);
console.log(out.pages.map(x=>`p${x.i}:${x.pct}%`).join("  "));
console.log("errors:", errs.slice(0,8).join(" | ")||"none");
// screenshot the first near-blank page (after the cover) + a known-content page for comparison
const blank=out.pages.find(x=>x.i>0 && x.pct<2 && x.w>1);
if(blank){ const secs=await p.$$("[data-role='local-hwp-page']"); await secs[blank.i].scrollIntoViewIfNeeded(); await p.waitForTimeout(500); await secs[blank.i].screenshot({path:`/tmp/hwp-blank-p${blank.i}.png`}); console.log("shot blank page", blank.i, "-> /tmp/hwp-blank-p"+blank.i+".png"); }
await b.close();
