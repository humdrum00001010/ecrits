import { chromium } from "@playwright/test";
const [, , DIR, DOC] = process.argv;
const BASE="http://localhost:4000";
const b=await chromium.launch({headless:true,args:["--no-sandbox"]});
const p=await b.newPage({viewport:{width:1200,height:1000}});
await p.goto(`${BASE}/workspace?path=${encodeURIComponent(DIR)}&document=${encodeURIComponent(DOC)}`,{waitUntil:"domcontentloaded",timeout:60000});
await p.waitForFunction(()=>!!window.__rhwpDoc,null,{timeout:60000}).catch(()=>{});
await p.waitForTimeout(5000);
const out=await p.evaluate(()=>{
  const d=window.__rhwpDoc; if(!d) return {error:"no __rhwpDoc"};
  const r={pageCount:d.pageCount(), sectionCount:(d.sectionCount&&d.sectionCount())??(d.getSectionCount&&d.getSectionCount())};
  const info=i=>{try{return d.getPageInfo(i);}catch(e){return "ERR:"+e.message;}};
  for(const i of [0,1,2,3,8,9]) r["pageInfo_"+i]=info(i);
  // controls (images/shapes) on page 1
  try{ r.ctrl1=(d.getPageControlLayout(1)||"").slice(0,200);}catch(e){r.ctrl1="ERR:"+e.message;}
  // does the doc model contain typical TOC text?
  try{ const h=d.searchAllText("목차"); r.tocHits=typeof h==="string"?h.slice(0,300):JSON.stringify(h).slice(0,300);}catch(e){r.tocErr=String(e.message);}
  // total paragraphs (sec 0)
  try{ r.paraCount_s0=d.getParagraphCount(0);}catch(e){}
  return r;
});
console.log(JSON.stringify(out,null,1));
await b.close();
