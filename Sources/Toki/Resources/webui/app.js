const TOKEN=new URLSearchParams(location.search).get("token")||"";
const $=s=>document.querySelector(s);
let current=null, offset=0, agents=[];
async function api(p,o){const r=await fetch(p+(p.includes("?")?"&":"?")+"token="+TOKEN,o);
  if(!r.ok)throw new Error(await r.text());return r.json()}
function esc(s){const d=document.createElement("div");d.textContent=s;return d.innerHTML}
function md(src){
  // escape, then fenced code, inline code, bold, italic, links, headings, bullets
  let s=esc(src);
  const fences=[];
  s=s.replace(/```[a-zA-Z0-9_-]*\n([\s\S]*?)```/g,(m,c)=>{fences.push(c);return "\u0000"+(fences.length-1)+"\u0000"});
  s=s.replace(/`([^`\n]+)`/g,"<code>$1</code>");
  s=s.replace(/\*\*([^*]+)\*\*/g,"<b>$1</b>");
  s=s.replace(/(^|[^*])\*([^*\n]+)\*(?!\*)/g,"$1<i>$2</i>");
  s=s.replace(/\[([^\]]+)\]\((https?:[^)\s]+)\)/g,'<a href="$2" target="_blank">$1</a>');
  s=s.split("\n").map(line=>{
    if(/^#{1,4}\s/.test(line))return "<p><b>"+line.replace(/^#{1,4}\s+/,"")+"</b></p>";
    if(/^\s*[-*]\s+/.test(line))return "<p>&bull; "+line.replace(/^\s*[-*]\s+/,"")+"</p>";
    if(/^\s*\d+\.\s+/.test(line))return "<p>"+line+"</p>";
    return line.length?"<p>"+line+"</p>":"";
  }).join("");
  s=s.replace(/\u0000(\d+)\u0000/g,(m,i)=>"<pre>"+fences[+i]+"</pre>");
  return s;
}
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
  if(!agents.length){btn.innerHTML='<span class="t">no agents found</span>';list.innerHTML="";return}
  const row=a=>providerLogo(a.provider)+'<span class="t">'+(a.attention?'<span class="dot">\u25cf</span> ':'')+esc(a.title)+'</span>';
  const cur=agents.find(a=>a.pid==current)||agents[0];
  btn.innerHTML=row(cur)+'<span class="caret">\u25be</span>';
  list.innerHTML=agents.map(a=>'<div class="dditem'+(a.pid==current?' sel':'')+'" data-pid="'+a.pid+'">'+row(a)+'</div>').join("");
  list.querySelectorAll(".dditem").forEach(el=>el.onclick=ev=>{
    ev.stopPropagation();current=+el.dataset.pid;offset=0;$("#log").innerHTML="";
    document.getElementById("dd").classList.remove("open");renderAgents();refreshLog();
  });
}
async function refreshAgents(){
  agents=await api("/api/agents");const prev=current;
  if(agents.length&&!agents.some(a=>a.pid==prev)){current=agents[0].pid;offset=0;$("#log").innerHTML=""}
  renderAgents();
  const a=agents.find(x=>x.pid==current), al=$("#alert");
  if(a&&a.attention){
    al.style.display="block";al.className=a.attention.kind=="question"?"q":"";
    const qs=a.attention.questions&&a.attention.questions.length?a.attention.questions
      :[{question:a.attention.prompt||"Agent is waiting on you",options:a.attention.options||[]}];
    al.innerHTML=qs.map(q=>'<div class="qq">'+md(q.question||"")+"</div>"+
      (q.options||[]).map((o,i)=>
        `<button class="opt" data-text="${i+1}">${i+1}. ${esc(o)}</button>`).join("")).join("");
  } else al.style.display="none";
}
async function refreshLog(){
  if(!current)return;
  const r=await api(`/api/transcript?pid=${current}&offset=${offset}`);
  if(r.reset){offset=0;$("#log").innerHTML="";return}
  offset=r.offset;
  for(const e of r.entries){
    if(e.role=="meta"||e.role=="resolved")continue;
    const d=document.createElement("div");d.className="m "+e.role;
    if(e.role=="tool")d.innerHTML="&#128295; <b>"+esc(e.tool)+"</b> "+esc(e.text||"");
    else if(e.role=="assistant")d.innerHTML=md(e.text);
    else d.textContent=e.text;
    $("#log").appendChild(d);
  }
  if(r.entries.length)window.scrollTo(0,document.body.scrollHeight);
}
async function send(body){
  if(!current)return;
  $("#status").textContent="sending\u2026";
  try{const r=await api("/api/send",{method:"POST",headers:{"Content-Type":"application/json"},
    body:JSON.stringify({pid:current,...body})});
    $("#status").textContent="delivered via "+r.how;
  }catch(e){$("#status").textContent="failed: "+e.message}
  setTimeout(()=>$("#status").textContent="",4000);
}
document.addEventListener("click",e=>{
  const b=e.target.closest("button");if(!b)return;
  if(b.id=="send"){const v=$("#msg").value.trim();if(v){send({text:v});$("#msg").value=""}}
  else if(b.dataset.key)send({key:b.dataset.key});
  else if(b.dataset.text)send({text:b.dataset.text,raw:true});
});
$("#msg").addEventListener("keydown",e=>{if(e.key=="Enter")$("#send").click()});
$("#ddbtn").addEventListener("click",e=>{e.stopPropagation();document.getElementById("dd").classList.toggle("open")});
document.addEventListener("click",()=>document.getElementById("dd").classList.remove("open"));
refreshAgents();refreshLog();
setInterval(refreshAgents,4000);setInterval(refreshLog,2500);
