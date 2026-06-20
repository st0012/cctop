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
