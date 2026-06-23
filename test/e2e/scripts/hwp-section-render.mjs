import { chromium } from "@playwright/test";
const [, , DIR, DOC] = process.argv;
const BASE="http://localhost:4000";
const b=await chromium.launch({headless:true,args:["--no-sandbox"]});
const p=await b.newPage({viewport:{width:1200,height:1000}});
await p.goto(`${BASE}/workspace?path=${encodeURIComponent(DIR)}&document=${encodeURIComponent(DOC)}`,{waitUntil:"domcontentloaded",timeout:60000});
await p.waitForFunction(()=>!!window.__rhwpDoc,null,{timeout:60000}).catch(()=>{});
await p.waitForTimeout(4000);
const out=await p.evaluate(async()=>{
  const d=window.__rhwpDoc; const n=Math.min(40,d.pageCount());
  const rows=[];
  for(let i=0;i<n;i++){
    let sec=-1,loc=-1;
    try{const pi=JSON.parse(d.getPageInfo(i)); sec=pi.sectionIndex; loc=pi.pageIndex;}catch(e){}
    const c=document.createElement("canvas");
    try{ d.renderPageToCanvas(i,c,1); }catch(e){}
    let nw=0,t=0; try{const im=c.getContext("2d").getImageData(0,0,c.width,c.height).data; for(let k=0;k<im.length;k+=4*97){t++; if(im[k]<250||im[k+1]<250||im[k+2]<250)nw++;}}catch(e){}
    rows.push({g:i,sec,loc,pct:t?+(100*nw/t).toFixed(0):0});
  }
  return rows;
});
// print compact table grouped by section
const bySec={};
for(const r of out){ (bySec[r.sec]=bySec[r.sec]||[]).push(r); }
for(const sec of Object.keys(bySec)){
  console.log("sec"+sec+": "+bySec[sec].map(r=>`[loc${r.loc}:${r.pct}%]`).join(" "));
}
await b.close();
