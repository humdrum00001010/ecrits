import { chromium } from "@playwright/test";
const [, , DIR, DOC] = process.argv;
const BASE="http://localhost:4000";
const b=await chromium.launch({headless:true,args:["--no-sandbox"]});
const p=await b.newPage({viewport:{width:1200,height:1000}});
await p.goto(`${BASE}/workspace?path=${encodeURIComponent(DIR)}&document=${encodeURIComponent(DOC)}`,{waitUntil:"domcontentloaded",timeout:60000});
await p.waitForFunction(()=>!!window.__rhwpDoc,null,{timeout:60000}).catch(()=>{});
await p.waitForTimeout(4000);
const out=await p.evaluate(async()=>{
  const d=window.__rhwpDoc; if(!d) return {error:"no __rhwpDoc"};
  const res={};
  for(const i of [0,1,2,3,8,9,10]){
    const c=document.createElement("canvas");
    let err=null, t0=performance.now(), ms=0;
    try{ d.renderPageToCanvas(i,c,1); }catch(e){ err=String(e&&e.message||e); }
    ms=+(performance.now()-t0).toFixed(1);
    let nonWhite=0,total=0;
    try{
      const ctx=c.getContext("2d");
      const img=ctx.getImageData(0,0,c.width,c.height).data;
      for(let k=0;k<img.length;k+=4*97){ total++; if(img[k]<250||img[k+1]<250||img[k+2]<250) nonWhite++; }
    }catch(e){ err=(err||"")+" sample:"+e.message; }
    res["p"+i]={w:c.width,h:c.height,ms,nonWhitePct:total?+(100*nonWhite/total).toFixed(1):0,err};
  }
  return res;
});
console.log(JSON.stringify(out,null,1));
await b.close();
