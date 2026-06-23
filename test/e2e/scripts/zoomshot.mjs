import { chromium } from "@playwright/test";
const BASE="http://localhost:4000", DIR="/Users/phihu/Downloads", DOC="기관별 연령별 인구통계(2026년 5월말 기준).xlsx";
const b=await chromium.launch({headless:true,args:["--no-sandbox"]});
const p=await b.newPage({viewport:{width:1200,height:900},deviceScaleFactor:1});
await p.goto(`${BASE}/workspace?path=${encodeURIComponent(DIR)}&document=${encodeURIComponent(DOC)}`,{waitUntil:"domcontentloaded",timeout:60000});
await p.waitForSelector("[data-editor-zoomable] canvas",{timeout:60000}); await p.waitForTimeout(5000);
for(let i=0;i<5;i++){ await p.$eval("[data-editor-zoomable]", el => el.querySelector("canvas").dispatchEvent(new WheelEvent("wheel",{ctrlKey:true,deltaY:-12,bubbles:true,cancelable:true}))); await p.waitForTimeout(60); }
console.log("zoom now:", await p.$eval("[data-editor-zoomable]", el=>el.style.zoom));
await p.waitForTimeout(400); await p.screenshot({path:"/tmp/zoomed.png"}); await b.close();
