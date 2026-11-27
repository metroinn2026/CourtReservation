const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const source=fs.readFileSync(process.env.COURT_ADMIN_SOURCE||path.join(__dirname,'../admin.html'),'utf8');
function target(width=600){
 const events=new Map();let left=0;
 return {clientWidth:width,scrollWidth:1400,isConnected:true,firstElementChild:{},events,
 get scrollLeft(){return left;},set scrollLeft(value){left=Math.max(0,Math.min(value,this.scrollWidth-this.clientWidth));},
 getBoundingClientRect(){return{left:300,right:300+this.clientWidth,top:100,bottom:3000};},
 addEventListener:(name,fn)=>events.set(name,fn),removeEventListener:name=>events.delete(name)};
}
function setup(){
 const barEvents=new Map(),windowEvents=new Map(),viewportEvents=new Map(),raf=new Map(),bars=[];let seq=1;
 const track={clientWidth:400,scrollLeft:0,firstElementChild:{style:{}},setAttribute(){},addEventListener:(name,fn)=>barEvents.set(name,fn),removeEventListener:name=>barEvents.delete(name)};
 const left={disabled:false},right={disabled:false},bar={hidden:true,style:{},querySelector:()=>track,querySelectorAll:()=>[left,right],remove(){this.removed=true;}};
 const defaultTable=target();
 const c=vm.createContext({Math,document:{querySelector:()=>defaultTable,documentElement:{clientWidth:1200},body:{appendChild:x=>bars.push(x)},createElement:()=>bar},window:{innerHeight:800,addEventListener:(event,fn)=>windowEvents.set(event,fn),removeEventListener:event=>windowEvents.delete(event),visualViewport:{addEventListener:(event,fn)=>viewportEvents.set(event,fn),removeEventListener:event=>viewportEvents.delete(event)}},requestAnimationFrame:fn=>{const id=seq++;raf.set(id,fn);return id;},cancelAnimationFrame:id=>raf.delete(id),ResizeObserver:class{observe(){}disconnect(){}}});
 const start=source.indexOf('let recordsBottomScrollbarCleanup='),end=source.indexOf('function renderRecordsTable(){',start);vm.runInContext(source.slice(start,end),c);
 return{c,bar,track,left,right,bars,defaultTable,windowEvents,viewportEvents,barEvents,tick(){for(const [id,fn] of raf){raf.delete(id);fn();}}};
}
test('fixed stage scrollbar moves the actual overflowing table in both directions',()=>{
 const s=setup(),wrap=target();s.c.bindRecordsBottomScrollbar(wrap);
 assert.equal(s.bar.hidden,false);assert.equal(s.bar.style.left,'300px');assert.equal(s.bar.style.width,'600px');
 s.right.onclick();assert.equal(wrap.scrollLeft,390);assert.equal(s.track.scrollLeft,390);
 s.track.scrollLeft=700;s.barEvents.get('scroll')();assert.equal(wrap.scrollLeft,700);
 s.left.onclick();assert.equal(wrap.scrollLeft,310);assert.equal(s.track.scrollLeft,310);
});
test('browser zoom or resize recomputes scrollbar size and cleans up listeners on close',()=>{
 const s=setup(),wrap=target();s.c.bindRecordsBottomScrollbar(wrap);wrap.clientWidth=450;s.windowEvents.get('resize')();s.tick();
 assert.equal(s.bar.style.width,'450px');assert.equal(s.track.firstElementChild.style.width,'1350px');
 s.c.removeRecordsBottomScrollbar();assert.equal(s.bar.removed,true);assert.equal(s.windowEvents.size,0);assert.equal(s.viewportEvents.size,0);assert.equal(wrap.events.size,0);
});
test('bar is hidden when no horizontal overflow and stage scrolling does not change regular list offset',()=>{
 const s=setup(),wrap=target(1500);s.c.bindRecordsBottomScrollbar(wrap);assert.equal(s.bar.hidden,true);
 const t=target();s.c.bindRecordsBottomScrollbar(t);s.right.onclick();s.c.removeRecordsBottomScrollbar();s.c.bindRecordsBottomScrollbar();assert.equal(s.defaultTable.scrollLeft,0);
});
test('stage editor has a constrained outer table and a horizontal-only inner wrapper',()=>{
 assert(source.includes('class="table-wrap stage-adjustment-list-wrap"'));
 assert.match(source,/#content \.stage-adjustment-list-wrap > table \{[^}]*table-layout:fixed!important/);
 assert.match(source,/#content \[data-stage-editor\] \.table-wrap \{[^}]*overflow-x:auto!important;overflow-y:hidden!important/);
 assert(source.includes("bindRecordsBottomScrollbar(host.querySelector('.stage-results-table-wrap'))"));assert(!source.includes('max-height:55vh'));
});
