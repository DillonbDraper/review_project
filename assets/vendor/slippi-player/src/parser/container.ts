// Read only the bounded raw element. Untrusted optional UBJSON metadata never
// controls allocations and is not needed for rendering or synchronization.
export function replayRaw(bytes: ArrayBuffer) {
 const data = new Uint8Array(bytes), view = new DataView(bytes);
 const header = [123,85,3,114,97,119,91,36,85,35,108];
 if(data.length < 15 || !header.every((b,i)=>data[i]===b)) throw Error('Malformed replay container.');
 const length=view.getUint32(11);
 if(!length || length>data.length-15) throw Error('Incomplete replay container.');
 return {raw:data.subarray(15,15+length)};
}

export function validateRaw(raw: Uint8Array) {
 const view=new DataView(raw.buffer,raw.byteOffset,raw.byteLength);
 const fail=()=>{throw Error('Choose a complete replay with supported stage and player data.');};
 if(raw[0]!==0x35 || raw[1]<=1 || (raw[1]-1)%3 || raw[1]>=raw.length) fail();
 const sizes=new Map<number,number>();
 for(let p=2;p<raw[1]+1;p+=3){if(sizes.has(raw[p]))fail();sizes.set(raw[p],view.getUint16(p+1));}
 let stage:number|undefined, required=0, ended=false, last=-1;
 const frames:number[]=[];
 const minima:Record<number,number>={0x37:58,0x38:33,0x3a:8,0x3b:37,0x3c:4,0x3f:9};
 for(let p=raw[1]+1;p<raw.length;){
  const code=raw[p],size=sizes.get(code);
  if(!size || p+1+size>raw.length || ended)fail();
  const at=p+1;
  if(code===0x36){
   if(stage!==undefined || size!<320)fail();
   stage=view.getUint16(at+18);if(![2,3,8,28,31,32].includes(stage))fail();
   let count=0;
   for(let i=0;i<4;i++) if(raw[at+101+36*i]!==3){
    if(![0,1].includes(raw[at+101+36*i]) || raw[at+100+36*i]>25 || raw[at+109+36*i]>2)fail();
    required|=(1<<i)|(1<<(i+4));count++;
   }
   if(![2,4].includes(count))fail();
  } else {
   if(stage===undefined)fail();
   if(minima[code]){
    if(size!<minima[code])fail();
    const frame=view.getInt32(at)+123;
    if(frame<0 || frame>last+1)fail();
    if(frame<last || (code===0x3a && frames[frame]!==undefined))frames.length=frame;
    last=frame;
    let mask=frames[frame]||0;
    if(code===0x37 || code===0x38){
     const player=raw[at+4],nana=raw[at+5];
     if(player>3 || nana>1 || !(required&(1<<player)))fail();
     if(code===0x38 && raw[at+6]>26)fail();
     const floats=code===0x38?[9,13,17,21,25]:[24,28,32,36,40,50,54];
     if(!floats.every(n=>Number.isFinite(view.getFloat32(at+n))))fail();
     mask|=1<<(player+(code===0x38?4:0)+nana*8);
     if(code===0x38 && !nana)mask|=1<<(player+(raw[at+32]===0?16:20));
    }
    if(code===0x3f && (![0,1].includes(raw[at+4]) || !Number.isFinite(view.getFloat32(at+5))))fail();
    frames[frame]=mask;
   }else if(code===0x39)ended=true;
  }
  p+=size!+1;
 }
 if(!ended || last<0)fail();
 let eliminated=0;
 for(let i=0;i<=last;i++) {
  const mask=frames[i],pre=mask&15,post=(mask>>>4)&15,missing=(required&15)&~pre;
  if(mask===undefined || !pre || pre!==post || (missing&~eliminated) || ((mask>>>8)&15)!==((mask>>>12)&15))fail();
  eliminated=(eliminated|((mask>>>16)&15))&~((mask>>>20)&15);
 }
 return {frames:last+1,stage,duration:(last+1)/60};
}
