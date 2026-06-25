/* Shared timeline helpers for every video. Loaded as a plain (non-module)
   <script> so these become globals the video's <script> can use directly. */
const $=s=>document.querySelector(s), $$=s=>[...document.querySelectorAll(s)];
const clamp=(x,a=0,b=1)=>x<a?a:x>b?b:x;
const lerp=(a,b,t)=>a+(b-a)*t;
const mix=(t,a,b)=>clamp((t-a)/(b-a));          // normalised progress within [a,b]
const eOut=t=>1-Math.pow(1-t,3);                // easeOutCubic
const eIn =t=>t*t*t;
const eInOut=t=>t<.5?4*t*t*t:1-Math.pow(-2*t+2,3)/2;
const eBack=t=>{const c1=1.70158,c3=c1+1;return 1+c3*Math.pow(t-1,3)+c1*Math.pow(t-1,2);};
/* reveal: fade/slide-up over [a,b], hold, fade-out over [c,d] -> {o,y} */
function rev(t,a,b,c,d,dy=42){
  let o=mix(t,a,b); if(d!==undefined) o*=(1-mix(t,c,d));
  const y=lerp(dy,0,eOut(mix(t,a,b))) + (d!==undefined?lerp(0,-dy*0.5,eIn(mix(t,c,d))):0);
  return {o,y};
}
function set(el,{o,x=0,y=0,s=1,blur=0,extra=''}){
  el.style.opacity=o; el.style.transform=`translate(${x}px,${y}px) scale(${s}) ${extra}`;
  el.style.filter=blur>0?`blur(${blur}px)`:'none';
}
/* The boot handshake every cut shares: expose seek to the renderer, wait for fonts + every
   asset, paint frame 0, then flag __ready. A broken/missing asset is recorded on window.__error
   (NOT silently treated as loaded) so render.mjs can fail the build instead of capturing a cut
   with missing visuals. Covers both <img> elements AND CSS mask/-webkit-mask URLs — the menubar
   pill and the stack tool logos are masked backgrounds, not <img>, so an <img>-only gate would
   miss a renamed/missing logo and render a blank icon. Keeps cuts from cloning this verbatim. */
function whenReady(seek){
  window.__seek=seek;
  const imgReady=im=> im.complete
    ? (im.naturalWidth>0 ? Promise.resolve() : Promise.reject(new Error(im.src)))
    : new Promise((res,rej)=>{ im.onload=res; im.onerror=()=>rej(new Error(im.src)); });
  const masks=new Set();
  $$('*').forEach(el=>{ const cs=getComputedStyle(el);
    const v=[cs.maskImage,cs.webkitMaskImage].find(x=>x && x!=='none');
    if(v){ const m=v.match(/url\(["']?([^"')]+)["']?\)/); if(m) masks.add(m[1]); } });
  const fetchOK=url=> fetch(url).then(r=>{ if(!r.ok) throw new Error(url); });
  Promise.all([document.fonts.ready, ...$$('#stage img').map(imgReady), ...[...masks].map(fetchOK)])
    .catch(e=>{ window.__error='asset failed to load: '+((e && e.message) || e); })
    .finally(()=>{ seek(0); requestAnimationFrame(()=>{ window.__ready=true; }); });
}
