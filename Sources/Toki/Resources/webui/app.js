// Fragments keep the token out of static-host access logs. Query params remain supported for
// links created from the original hosting plan.
const PARAMS=new URLSearchParams(location.hash.slice(1)||location.search);
const LINK_TOKEN=PARAMS.get("token")||"";
const REMOTE_HOST=PARAMS.get("host")||"";
let API_BASE="",CONFIG_ERROR="";
try{API_BASE=REMOTE_HOST?remoteAPIBase(REMOTE_HOST):""}catch(e){CONFIG_ERROR=e.message}
function remoteAPIBase(host){
  if(!/^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\.ts\.net$/i.test(host))
    throw new Error("Invalid Tailscale host");
  return "https://"+host;
}
const $=s=>document.querySelector(s);
function feedback(kind="tap"){
  if(!navigator.vibrate)return;
  const pattern=kind=="success"?[10,24,10]:kind=="error"?[24,35,24]:7;
  navigator.vibrate(pattern);
}
const SESSION_KEY="toki-session:"+API_BASE+":"+LINK_TOKEN;
let TOKEN="";
try{TOKEN=sessionStorage.getItem(SESSION_KEY)||""}catch(e){}
let current=null, offset=0, agents=[];
async function api(p,o){const url=API_BASE+p+(p.includes("?")?"&":"?")+"token="+encodeURIComponent(TOKEN);
  const r=await fetch(url,o);
  if(r.status==403)lockApp();
  if(!r.ok)throw new Error(await r.text());return r.json()}
function lockApp(){
  TOKEN="";try{sessionStorage.removeItem(SESSION_KEY)}catch(e){}
  document.body.classList.add("locked");
  $("#paircontrols").hidden=false;
  $("#connectmethods").hidden=true;
  $("#pairtitle").textContent="Verify this device";
  $("#pairinstructions").textContent="Enter the six-digit code shown by Toki on your Mac.";
  $("#paircode").focus();
}
function invalidLink(message){
  TOKEN="";try{sessionStorage.removeItem(SESSION_KEY)}catch(e){}
  document.body.classList.add("locked");
  $("#pairtitle").textContent="Open a new link from Toki";
  $("#pairinstructions").textContent=message;
  $("#paircontrols").hidden=true;
  $("#connectmethods").hidden=false;
  $("#pairstatus").textContent="";
}
let started=false,failCount=0;
function setConnected(ok){
  if(ok){failCount=0;$("#conn").hidden=true;return}
  if(document.body.classList.contains("locked"))return;
  if(++failCount>=2)$("#conn").hidden=false;
}
function pollAgents(){if(TOKEN)refreshAgents().then(()=>setConnected(true),()=>setConnected(false))}
function pollLog(){if(TOKEN)refreshLog().then(()=>setConnected(true),()=>setConnected(false))}
function startApp(){
  document.body.classList.remove("locked");
  updateAlertsButton();
  if(started)return;started=true;
  pollAgents();pollLog();
  setInterval(pollAgents,4000);setInterval(pollLog,2500);
}
$("#pairform").addEventListener("submit",async e=>{
  e.preventDefault();
  const code=$("#paircode").value.replace(/\s/g,"");
  if(!/^\d{6}$/.test(code)){$("#pairstatus").textContent="Enter all six digits.";return}
  $("#pairstatus").textContent="verifying\u2026";
  try{
    const r=await fetch(API_BASE+"/api/pair?token="+encodeURIComponent(LINK_TOKEN),{
      method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({code})
    });
    const body=await r.json();
    if(!r.ok){
      if(body.error=="bad link token"){
        invalidLink("This Remote Control link is invalid or expired. Open Connect in Toki and use its latest link.");
        return;
      }
      if(body.error=="incorrect verification code")throw new Error("That code is incorrect or has rotated. Check the current code in Toki and try again.");
      throw new Error(body.error||"verification failed");
    }
    TOKEN=body.token;try{sessionStorage.setItem(SESSION_KEY,TOKEN)}catch(e){}
    $("#pairstatus").textContent="";startApp();
  }catch(err){feedback("error");$("#pairstatus").textContent=err.message}
});
function esc(s){const d=document.createElement("div");d.textContent=s;return d.innerHTML}
const md=renderMarkdown;
const LOGOS={
  claude:'<svg class="plogo" viewBox="0 0 100 100" fill="#d97757"><path d="m19.6 66.5 19.7-11 .3-1-.3-.5h-1l-3.3-.2-11.2-.3L14 53l-9.5-.5-2.4-.5L0 49l.2-1.5 2-1.3 2.9.2 6.3.5 9.5.6 6.9.4L38 49.1h1.6l.2-.7-.5-.4-.4-.4L29 41l-10.6-7-5.6-4.1-3-2-1.5-2-.6-4.2 2.7-3 3.7.3.9.2 3.7 2.9 8 6.1L37 36l1.5 1.2.6-.4.1-.3-.7-1.1L33 25l-6-10.4-2.7-4.3-.7-2.6c-.3-1-.4-2-.4-3l3-4.2L28 0l4.2.6L33.8 2l2.6 6 4.1 9.3L47 29.9l2 3.8 1 3.4.3 1h.7v-.5l.5-7.2 1-8.7 1-11.2.3-3.2 1.6-3.8 3-2L61 2.6l2 2.9-.3 1.8-1.1 7.7L59 27.1l-1.5 8.2h.9l1-1.1 4.1-5.4 6.9-8.6 3-3.5L77 13l2.3-1.8h4.3l3.1 4.7-1.4 4.9-4.4 5.6-3.7 4.7-5.3 7.1-3.2 5.7.3.4h.7l12-2.6 6.4-1.1 7.6-1.3 3.5 1.6.4 1.6-1.4 3.4-8.2 2-9.6 2-14.3 3.3-.2.1.2.3 6.4.6 2.8.2h6.8l12.6 1 3.3 2 1.9 2.7-.3 2-5.1 2.6-6.8-1.6-16-3.8-5.4-1.3h-.8v.4l4.6 4.5 8.3 7.5L89 80.1l.5 2.4-1.3 2-1.4-.2-9.2-7-3.6-3-8-6.8h-.5v.7l1.8 2.7 9.8 14.7.5 4.5-.7 1.4-2.6 1-2.7-.6-5.8-8-6-9-4.7-8.2-.5.4-2.9 30.2-1.3 1.5-3 1.2-2.5-2-1.4-3 1.4-6.2 1.6-8 1.3-6.4 1.2-7.9.7-2.6v-.2H49L43 72l-9 12.3-7.2 7.6-1.7.7-3-1.5.3-2.8L24 86l10-12.8 6-7.9 4-4.6-.1-.5h-.3L17.2 77.4l-4.7.6-2-2 .2-3 1-1 8-5.5Z"/></svg>',
  codex:'<svg class="plogo" viewBox="0 0 250 250" fill="#7a9dff"><path d="m84.3 5.1q3.7-1.5 7.7-2.6 3.9-1 7.9-1.6 4-0.5 8.1-0.6 4 0 8 0.5 20.7 2.4 37.1 17.7 0.1 0.1 0.4 0.3 0.1 0 0.2 0 0 0 0.2 0 0 0 0.1 0 0 0 0.1 0 5.2-1.4 10.7-1.9 5.4-0.4 10.7 0.1 5.5 0.4 10.7 1.9 5.2 1.3 10.1 3.6l0.6 0.4 1.6 0.8q5.2 2.5 9.7 6.1 4.7 3.4 8.6 7.7 3.8 4.3 6.9 9.2 3 4.8 5.2 10.2 4.3 10.5 4.3 22.1 0.2 2.1 0 4.2-0.1 2.2-0.2 4.3-0.3 2.1-0.7 4.3-0.4 2.1-0.9 4.1 0 0.2 0 0.4 0 0.2 0 0.5 0 0.1 0.1 0.4 0.1 0.1 0.3 0.3 12.3 12.6 16.3 30 6 29.7-12.2 53.5l-1.9 2.2q-3 3.5-6.5 6.4-3.4 3.1-7.3 5.5-3.8 2.4-8.1 4.2-4.1 1.9-8.5 3.2-0.3 0-0.4 0.2-0.3 0-0.4 0.1-0.1 0.1-0.3 0.4 0 0.1-0.1 0.3c-2.7 7.7-5.3 14.2-10.2 20.7-12.5 16.5-30.8 25.5-51.5 25.5q-24.6-0.1-43.6-18.1-0.2-0.1-0.4-0.2-0.2-0.1-0.4-0.1-0.2 0-0.3 0-0.3 0-0.4 0c-5.4 1.7-10.9 1.9-16.7 1.9q-3.5 0-7-0.5-3.4-0.4-6.9-1.2-3.3-0.8-6.6-2-3.3-1.2-6.4-2.8-3.3-1.6-6.4-3.6-3-2-5.8-4.3-3-2.3-5.5-5-2.5-2.6-4.6-5.6c-2.2-2.7-4.3-5.4-5.8-8.5q-0.8-1.6-1.6-3.2-0.6-1.7-1.3-3.3-0.7-1.7-1.2-3.4-0.5-1.6-1-3.4-1.1-4-1.6-7.9-0.6-4-0.6-8 0-4 0.6-8 0.4-4 1.4-8 0 0 0-0.1 0-0.1 0-0.1 0.2-0.2 0.2-0.3 0-0.1-0.2-0.1 0-0.2 0-0.3 0-0.1-0.1-0.1 0-0.2 0-0.2-0.1-0.1-0.1-0.1-2.4-2.5-4.6-5.2-2.1-2.7-4-5.4-1.7-3-3.2-6-1.5-3.1-2.6-6.3-0.8-2-1.3-4.1-0.7-2-1.1-4-0.4-2.1-0.7-4.2-0.2-2.2-0.4-4.3-0.2-2.8-0.1-5.6 0-2.8 0.3-5.4 0.1-2.8 0.6-5.6 0.4-2.8 1.1-5.5 7-23.1 26.9-36.3 4.3-2.9 8.2-4.5 4.5-1.9 9-3.2 0.2 0 0.3-0.1 0.1-0.2 0.3-0.3 0.1 0 0.1-0.3 0.1-0.1 0.1-0.2 1-3.1 2.2-6 1-2.9 2.5-5.7 1.5-3 3.2-5.6 1.7-2.7 3.7-5.1 2.5-3.2 5.3-5.9 3-2.8 6.1-5.4 3.2-2.4 6.8-4.4 3.5-2 7.2-3.5zm48.3 146.4c-2.3 0.1-4.4 1-6 2.8-1.5 1.6-2.4 3.7-2.4 5.9 0 2.3 0.9 4.4 2.4 6.2 1.6 1.6 3.7 2.5 6 2.6h50.4c2.4 0.1 4.8-0.6 6.5-2.4 1.7-1.6 2.8-4 2.8-6.4 0-2.4-1.1-4.7-2.8-6.3-1.7-1.8-4.1-2.6-6.5-2.4zm-56.7-64.9c-1.2-1.9-3-3.4-5.3-3.9-2.2-0.5-4.5-0.3-6.5 0.9-2 1.1-3.5 3-4.1 5.2-0.7 2.2-0.4 4.6 0.6 6.5l17.7 30.9-17.5 29.5c-1.2 2-1.6 4.5-1.1 6.8 0.7 2.3 2.1 4.1 4.1 5.3 2 1.2 4.4 1.6 6.7 0.9 2.2-0.5 4.2-1.9 5.4-3.9l20.1-34.1q0.7-0.9 0.9-2.1 0.3-1.1 0.3-2.3 0-1.2-0.3-2.2-0.2-1.2-0.8-2.2z"/></svg>',
  opencode:'<svg class="plogo" viewBox="0 0 240 300"><rect x="60" y="60" width="120" height="180" fill="#f1ecec"/><rect x="60" y="120" width="120" height="120" fill="#4b4646"/></svg>',
};
function providerLogo(p){
  if(p=="claude"||p=="claudeCode"||p=="anthropic")return LOGOS.claude;
  if(p=="codex"||p=="openai"||p=="chatgpt")return LOGOS.codex;
  if(p=="opencode"||p=="openCode")return LOGOS.opencode;
  return '<svg class="plogo" viewBox="0 0 24 24" fill="#888"><circle cx="12" cy="12" r="8"/></svg>';
}
function renderAgents(){
  const btn=$("#ddbtn"),list=$("#ddlist");
  if(!agents.length){
    btn.innerHTML='<span class="t">no agents found</span>';list.innerHTML="";
    updateComposer(null);return
  }
  const row=a=>providerLogo(a.provider)+'<span class="t">'+(a.attention?'<span class="dot">\u25cf</span> ':'')+esc(a.title)+'</span>';
  const cur=agents.find(a=>a.pid==current)||agents[0];
  btn.innerHTML=row(cur)+'<span class="caret">\u25be</span>';
  updateComposer(cur);
  list.innerHTML=agents.map(a=>'<div class="dditem'+(a.pid==current?' sel':'')+'" data-pid="'+a.pid+'">'+row(a)+'</div>').join("");
  list.querySelectorAll(".dditem").forEach(el=>el.onclick=ev=>{
    ev.stopPropagation();current=+el.dataset.pid;offset=0;$("#log").innerHTML="";
    document.getElementById("dd").classList.remove("open");renderAgents();refreshLog();
  });
}
function updateComposer(agent){
  const writable=!!(agent&&agent.writable),enabled=writable&&!sending;
  $("#readonly").style.display=agent&&!writable?"block":"none";
  document.querySelectorAll("footer button,footer input,footer textarea").forEach(el=>el.disabled=!enabled);
  $("#msg").placeholder=writable?"Reply to the agent\u2026":(agent?"Read-only session":"No active session");
}
let notifiedAttention={},notifySeeded=false;
function attentionKey(a){
  if(!a.attention)return"";
  const q=a.attention.questions&&a.attention.questions.length
    ?a.attention.questions.map(x=>x.question).join("|"):(a.attention.prompt||"");
  return a.attention.kind+":"+q;
}
function notifyAttention(list){
  if(!("Notification"in window)||Notification.permission!="granted"){notifiedAttention={};return}
  const seen={};
  for(const a of list){
    const key=attentionKey(a);if(!key)continue;
    seen[a.pid]=key;
    if(notifySeeded&&notifiedAttention[a.pid]!=key)showAttentionNotification(a);
  }
  notifiedAttention=seen;notifySeeded=true;
}
function showAttentionNotification(a){
  const kind=a.attention.kind=="permission"?"needs approval":"needs your input";
  const q=(a.attention.questions&&a.attention.questions[0]&&a.attention.questions[0].question)
    ||a.attention.prompt||"";
  const opts={body:q.replace(/[#*`>]/g,"").trim().slice(0,140),tag:"toki-"+a.pid,
    renotify:true,data:{pid:a.pid}};
  const title=a.title+" "+kind;
  if(navigator.serviceWorker&&navigator.serviceWorker.ready)
    navigator.serviceWorker.ready.then(r=>r.showNotification(title,opts))
      .catch(()=>{try{new Notification(title,opts)}catch(e){}});
  else try{new Notification(title,opts)}catch(e){}
}
function updateAlertsButton(){
  $("#enablealerts").hidden=!("Notification"in window)||Notification.permission!="default"||!TOKEN;
}
async function refreshAgents(){
  agents=await api("/api/agents");const prev=current;
  notifyAttention(agents);
  if(agents.length&&!agents.some(a=>a.pid==prev)){current=agents[0].pid;offset=0;$("#log").innerHTML=""}
  renderAgents();
  const a=agents.find(x=>x.pid==current), al=$("#alert");
  if(a&&a.attention){
    al.style.display="block";al.className=a.attention.kind=="question"?"q":"";
    const qs=a.attention.questions&&a.attention.questions.length?a.attention.questions
      :[{question:a.attention.prompt||"Agent is waiting on you",options:a.attention.options||[]}];
    al.innerHTML=qs.map(q=>'<div class="qq">'+md(q.question||"")+"</div>"+
      (q.options||[]).map((o,i)=>
        `<button class="opt" data-text="${i+1}"><b>${i+1}</b>&ensp;${esc(o)}</button>`).join("")).join("")+
      (a.attention.kind=="permission"?'<div class="decision-row"><button class="decision approve" data-key="enter">&#10003; Approve</button><button class="decision reject" data-key="esc">&#10005; Reject</button></div>':"");
  } else al.style.display="none";
}
function nearBottom(){return window.innerHeight+window.scrollY>=document.body.scrollHeight-140}
function scrollToLatest(){window.scrollTo(0,document.body.scrollHeight);$("#tolatest").hidden=true}
async function refreshLog(){
  if(!current)return;
  const r=await api(`/api/transcript?pid=${current}&offset=${offset}`);
  if(r.reset){offset=0;$("#log").innerHTML="";return}
  offset=r.offset;
  const stick=nearBottom();let added=0;
  for(const e of r.entries){
    if(e.role=="meta"||e.role=="resolved")continue;
    const d=document.createElement("div");d.className="m "+e.role;
    if(e.role=="tool")d.innerHTML="&#128295; <b>"+esc(e.tool)+"</b> "+esc(e.text||"");
    else if(e.role=="assistant")d.innerHTML=md(e.text);
    else d.textContent=e.text;
    $("#log").appendChild(d);added++;
  }
  if(added){if(stick)scrollToLatest();else $("#tolatest").hidden=false}
}
let sending=false,statusTimer=null;
function setStatus(message,kind){
  clearTimeout(statusTimer);$("#status").textContent=message;$("#status").className=kind||"";
}
async function send(body){
  if(!current||sending)return false;
  const agent=agents.find(a=>a.pid==current);
  if(!agent||!agent.writable)return false;
  sending=true;updateComposer(agent);setStatus("Sending\u2026","sending");
  try{const r=await api("/api/send",{method:"POST",headers:{"Content-Type":"application/json"},
    body:JSON.stringify({pid:current,...body})});
    feedback("success");setStatus("Sent \u2713 via "+r.how,"success");
    return true;
  }catch(e){feedback("error");setStatus("Couldn\u2019t send: "+e.message,"error");return false}
  finally{
    sending=false;updateComposer(agents.find(a=>a.pid==current)||null);
    statusTimer=setTimeout(()=>setStatus("",""),4000);
  }
}
document.addEventListener("pointerdown",e=>{
  const button=e.target.closest("button");if(button&&!button.disabled)feedback("tap");
},{passive:true});
document.addEventListener("click",async e=>{
  const b=e.target.closest("button");if(!b)return;
  if(b.id=="send"){
    const input=$("#msg"),v=input.value.trim();
    if(v&&await send({text:v})&&input.value.trim()==v){input.value="";resizeComposer()}
  } else if(b.dataset.key)await send({key:b.dataset.key});
  else if(b.dataset.text)await send({text:b.dataset.text,raw:true});
});
function resizeComposer(){
  const input=$("#msg");input.style.height="auto";
  input.style.height=Math.min(input.scrollHeight,132)+"px";
}
$("#msg").addEventListener("input",resizeComposer);
$("#msg").addEventListener("keydown",e=>{
  if(e.key=="Enter"&&!e.isComposing&&(e.metaKey||e.ctrlKey)){e.preventDefault();$("#send").click()}
});
const footer=$("footer");
new ResizeObserver(()=>document.documentElement.style.setProperty("--footer-height",footer.offsetHeight+"px")).observe(footer);
resizeComposer();
$("#ddbtn").addEventListener("click",e=>{e.stopPropagation();document.getElementById("dd").classList.toggle("open")});
document.addEventListener("click",()=>document.getElementById("dd").classList.remove("open"));
$("#tolatest").addEventListener("click",scrollToLatest);
window.addEventListener("scroll",()=>{if(nearBottom())$("#tolatest").hidden=true},{passive:true});
$("#enablealerts").addEventListener("click",async()=>{
  try{await Notification.requestPermission()}catch(e){}
  updateAlertsButton();
});

// Enter a fresh link from another device: scan Toki's Connect QR, or type its host and token.
// Both reload with the params in the fragment so the normal verify flow takes over.
function connectWith(host,token){
  location.hash="host="+encodeURIComponent(host)+"&token="+encodeURIComponent(token);
  location.reload();
}
function manualConnect(){
  const host=$("#manualhost").value.trim().replace(/^https?:\/\//i,"").replace(/\/+$/,"");
  const token=$("#manualtoken").value.trim();
  if(!token){feedback("error");$("#pairstatus").textContent="Enter the connection token from Toki.";return}
  try{remoteAPIBase(host)}catch(e){feedback("error");$("#pairstatus").textContent="Enter your Mac\u2019s Tailscale host, like name.tailnet.ts.net.";return}
  connectWith(host,token);
}
$("#manualconnect").addEventListener("click",manualConnect);
[$("#manualhost"),$("#manualtoken")].forEach(el=>el.addEventListener("keydown",e=>{
  if(e.key=="Enter"){e.preventDefault();manualConnect()}
}));

// Scan Toki's Connect QR straight from the landing page, then verify the same way as an opened link.
const CAN_SCAN=!!(navigator.mediaDevices&&navigator.mediaDevices.getUserMedia&&window.isSecureContext);
$("#scanbtn").hidden=!CAN_SCAN;
$("#scanor").hidden=!CAN_SCAN;
let scanStream=null,scanRAF=null,scanDetector=null,jsqrPromise=null,lastScanValue="",lastScanAt=0,scanErrTimer=null;
const scanCanvas=document.createElement("canvas");
function loadJsQR(){
  if(window.jsQR)return Promise.resolve();
  if(!jsqrPromise)jsqrPromise=new Promise((res,rej)=>{
    const s=document.createElement("script");s.src="jsqr.js";
    s.onload=res;s.onerror=()=>rej(new Error("load failed"));document.head.appendChild(s);
  });
  return jsqrPromise;
}
async function openScanner(){
  const video=$("#scanvideo");$("#scanstatus").textContent="";$("#scanner").hidden=false;
  try{
    scanStream=await navigator.mediaDevices.getUserMedia({video:{facingMode:{ideal:"environment"}}});
    video.srcObject=scanStream;await video.play();
  }catch(e){
    $("#scanstatus").textContent=e.name=="NotAllowedError"?"Allow camera access, then tap Scan again.":"Couldn\u2019t open the camera: "+e.message;
    return;
  }
  if("BarcodeDetector" in window){try{scanDetector=new BarcodeDetector({formats:["qr_code"]})}catch(e){scanDetector=null}}
  if(!scanDetector){try{await loadJsQR()}catch(e){$("#scanstatus").textContent="Couldn\u2019t load the scanner. Check your connection and retry.";return}}
  scanRAF=requestAnimationFrame(scanTick);
}
function closeScanner(){
  if(scanRAF)cancelAnimationFrame(scanRAF);scanRAF=null;
  if(scanStream){scanStream.getTracks().forEach(t=>t.stop());scanStream=null}
  $("#scanvideo").srcObject=null;$("#scanner").hidden=true;scanDetector=null;
}
function decodeFrame(video){
  if(scanDetector)return scanDetector.detect(video).then(c=>c.length?c[0].rawValue:null).catch(()=>null);
  if(!window.jsQR)return Promise.resolve(null);
  const w=video.videoWidth,h=video.videoHeight;scanCanvas.width=w;scanCanvas.height=h;
  const ctx=scanCanvas.getContext("2d",{willReadFrequently:true});ctx.drawImage(video,0,0,w,h);
  const img=ctx.getImageData(0,0,w,h);
  const code=window.jsQR(img.data,w,h,{inversionAttempts:"dontInvert"});
  return Promise.resolve(code?code.data:null);
}
async function scanTick(){
  if(!scanStream)return;
  const video=$("#scanvideo");
  if(video.readyState>=2&&video.videoWidth){
    let value=null;try{value=await decodeFrame(video)}catch(e){}
    if(value&&!(value==lastScanValue&&Date.now()-lastScanAt<2500)){
      lastScanValue=value;lastScanAt=Date.now();handleScan(value);
    }
  }
  if(scanStream)scanRAF=requestAnimationFrame(scanTick);
}
function scanError(msg){
  $("#scanstatus").textContent=msg;feedback("error");
  clearTimeout(scanErrTimer);scanErrTimer=setTimeout(()=>{$("#scanstatus").textContent=""},2600);
}
function handleScan(value){
  let target;try{target=new URL(value,location.href)}catch(e){return scanError("That QR code isn\u2019t a Toki link.")}
  const params=new URLSearchParams(target.hash.slice(1)||target.search);
  if(!params.get("token")||target.origin!=location.origin)
    return scanError("That QR isn\u2019t a Toki Remote Control link for this page.");
  feedback("success");closeScanner();
  location.hash=target.hash?target.hash.slice(1):target.search.slice(1);
  location.reload();
}
$("#scanbtn").addEventListener("click",openScanner);
$("#scancancel").addEventListener("click",closeScanner);
document.addEventListener("visibilitychange",()=>{if(document.hidden&&scanStream)closeScanner()});
if("serviceWorker" in navigator&&window.isSecureContext)
  window.addEventListener("load",()=>navigator.serviceWorker.register("sw.js").catch(()=>{}));
if(CONFIG_ERROR)invalidLink("This link has an invalid server address. Open Connect in Toki and use a new link.");
else if(!LINK_TOKEN)invalidLink("This page needs a private link from Toki. Open Remote Control settings on your Mac, then choose Connect.");
else if(TOKEN)startApp();else lockApp();
