// Native resources only: files, grants, parsed frames, workers and renderer handles.
import {mount} from '../vendor/slippi-player/runtime.mjs';
import manifest from '../vendor/slippi-player/manifest.json' with {type:'json'};

export function parseReplayFile(file, {inspectOnly = false, signal, env = globalThis} = {}) {
  return new Promise((resolve, reject) => {
    const worker = new env.Worker(manifest['worker.mjs'], {type:'module'});
    let timer, settled=false;
    const done = (error, result) => {
      if(settled)return;settled=true;
      clearTimeout(timer); worker.terminate(); signal?.removeEventListener('abort', aborted);
      error ? reject(error) : resolve(result);
    };
    const aborted = () => done(Error('Replay preparation cancelled.'));
    signal?.addEventListener('abort', aborted, {once:true});
    if (signal?.aborted) return aborted();
    timer = setTimeout(()=>done(Error('Replay preparation timed out.')), 30_000);
    worker.onmessage=({data})=>data.error?done(Error(data.error)):done(null,data);
    worker.onerror=()=>done(Error('Replay could not be parsed.'));
    worker.postMessage({file,inspectOnly});
  });
}

export function createReplayResources(env=globalThis, {mountReplay=mount}={}) {
  let pending,channel,local;
  const entries=new Map();
  const releaseEntry=entry=>{entry?.renderer?.destroy();entry?.scene?.remove();};
  const grant=(signal,selection=null)=>new Promise((resolve,reject)=>{
    const current=channel;
    if(!current)return reject(Error('Rejoin the room before opening a replay.'));
    let settled=false;
    const finish=(error,value)=>{if(settled)return;settled=true;signal?.removeEventListener('abort',aborted);error?reject(error):resolve(value);};
    const aborted=()=>finish(Error('Replay preparation cancelled.'));
    signal?.addEventListener('abort',aborted,{once:true});
    if(signal?.aborted)return aborted();
    const push=current.push(selection?'replay_select':'replay_grant',selection||{});
    push.receive('ok',result=>channel===current?finish(null,result.grant):aborted());
    push.receive('error',()=>finish(Error('Replay admission expired. Rejoin the room.')));
    push.receive('timeout',()=>finish(Error('Replay admission timed out. Try again.')));
  });
  const cancel=()=>{
    const prior=pending;pending=null;prior?.controller.abort();
    if(prior?.selection)channel?.push("replay_cancel",{selection:prior.selection});
    if(prior?.handle && prior.handle!==local){releaseEntry(entries.get(prior.handle));entries.delete(prior.handle);}
  };
  const release=()=>{cancel();for(const entry of entries.values())releaseEntry(entry);entries.clear();local=null;};
  const resources={
    cancel,release,
    preparationFailed(){channel?.push("replay_preparation_failure",{});},
    bind(next){cancel();channel=next;},
    commitLocal(handle){
      if(!entries.has(handle))return;
      local=handle;
      if(pending?.handle===handle)pending.handle=null;
      for(const [key,entry] of entries)if(key!==handle){releaseEntry(entry);entries.delete(key);}
    },
    retainSource(source){
      const retained=source?.delivery==='local'?source.handle:null;
      // A room broadcast can beat the publishing HTTP response. Releasing old
      // local buffers must not abort that upload or hide its accepted result.
      for(const [key,entry] of entries)if(key!==retained){releaseEntry(entry);entries.delete(key);}
      if(local!==retained)local=null;
    },
    async scene(source,signal) {
      const entry=entries.get(source.handle);
      if(!entry)throw Error('Local replay released. Open the replay again.');
      if(!entry.renderer){entry.scene=env.document.createElement('div');entry.scene.className='slippi-player';entry.renderer=await mountReplay(entry.scene,entry.replay,signal);}
      return entry;
    },
    choose(params) {
      cancel();
      const input=env.document.createElement('input');input.type='file';input.accept='.slp';
      const task=pending={controller:new AbortController(),handle:null};
      const {signal}=task.controller;
      const emit=(status,message,result=null)=>{
        if(pending===task)env.Hologram?.dispatchAction('replay_result','video-panel',{request:params.request,generation:params.generation,status,message,result});
      };
      input.addEventListener('cancel',()=>emit('cancelled',''));
      input.onchange=async()=>{
        const file=input.files?.[0];if(!file||pending!==task)return;
        let deadline;
        try {
          if(!file.name.toLowerCase().endsWith('.slp'))throw Error('Choose a .slp replay file.');
          emit('preparing','Preparing replay…');
          if(params.solo){
            // Cover parsing AND animation readiness with the preparation deadline.
            deadline=setTimeout(()=>{emit('error','Replay preparation timed out.');cancel();},30_000);
            const {replay,metadata}=await parseReplayFile(file,{signal,env});
            if(signal.aborted)return;
            const handle=env.crypto.randomUUID();task.handle=handle;
            const scene=env.document.createElement('div');scene.className='slippi-player';
            const entry={replay,scene,renderer:null};entries.set(handle,entry);
            entry.renderer=await mountReplay(scene,replay,signal);
            if(signal.aborted){releaseEntry(entry);entries.delete(handle);return;}
            emit('accepted','Replay ready.',{...metadata,id:handle,handle,kind:'slippi_replay',delivery:'local',name:file.name,size:file.size});
          } else {
            await parseReplayFile(file,{inspectOnly:true,signal,env});
            if(signal.aborted)return;
            task.selection=env.crypto.randomUUID();
            const token=await grant(signal,{...params,selection:task.selection});
            emit('uploading','Uploading replay…');
            const {csrf_token}=await env.fetch('/room-session',{credentials:'same-origin',cache:'no-store',signal}).then(r=>r.json());
            const response=await env.fetch(`/rooms/${params.room_id}/replay`,{
              method:'POST',credentials:'same-origin',signal,
              headers:{'content-type':'application/octet-stream','x-csrf-token':csrf_token,'x-replay-grant':token,'x-replay-selection':task.selection,'x-replay-name':encodeURIComponent(file.name),'x-replay-size':String(file.size),
                'x-room-epoch':params.epoch,'x-room-revision':String(params.revision),'x-room-authority':String(params.authority_revision),'x-seat-generation':String(params.connection_generation)},body:file,
            });
            const result=await response.json();
            if(!response.ok)throw Error(result.reason||'Replay upload failed.');
            emit('accepted','Replay uploaded.',result);
          }
        }catch(error){
          if(pending===task&&!signal.aborted){
            resources.preparationFailed();
            if(task.handle){releaseEntry(entries.get(task.handle));entries.delete(task.handle);task.handle=null;}
            emit('error',error.message||'Replay preparation failed.');
          }
        }finally{clearTimeout(deadline);}
      };
      input.click();
    },
    async download(source,signal){
      const token=await grant(signal);
      const response=await env.fetch(`/rooms/${source.room_id}/replay/${source.id}`,{credentials:'same-origin',cache:'no-store',signal,headers:{'x-replay-grant':token}});
      if(!response.ok)throw Error('Replay unavailable. Rejoin the room or choose another source.');
      return response.blob();
    },
  };
  // A cached document can survive pagehide. Release parsed data now, rather
  // than retaining it until pageshow or the browser discards that document.
  env.addEventListener?.('pagehide',()=>{release();channel=null;});
  return resources;
}
export const ReplayUpload = globalThis.ReviewReplayResources ||= createReplayResources();

export async function createReplayPlayer(host, source, videoId, {signal,onChange,env=globalThis}={}) {
  const resources=env.ReviewReplayResources||ReplayUpload;
  let scene,renderer,duration,localEntry;
  if(source.delivery==='local'){
    const entry=localEntry=await resources.scene(source,signal);({scene,renderer}=entry);duration=entry.replay.frames.length/60;
  }else{
    const {replay}=await parseReplayFile(await resources.download(source,signal),{signal,env});
    if(signal?.aborted)throw Error('Replay preparation cancelled.');
    scene=env.document.createElement('div');scene.className='slippi-player';
    try{renderer=await mount(scene,replay,signal);}catch(error){scene.remove();throw error;}
    duration=replay.frames.length/60;
  }
  if(signal?.aborted){renderer.destroy();scene.remove();throw Error('Replay preparation cancelled.');}
  host.replaceChildren(scene);
  let position=0,anchor=env.performance.now(),playing=false,rate=1,destroyed=false,raf;
  const current=()=>Math.min(duration,position+(playing?(env.performance.now()-anchor)*rate/1000:0));
  const paint=()=>{
    if(destroyed)return;
    const at=current(),frame=Math.min(Math.round(duration*60)-1,Math.floor(at*60));
    renderer.frame(frame);scene.dataset.frame=String(frame);
    if(at>=duration&&playing){position=duration;playing=false;onChange?.();}
  };
  const tick=()=>{paint();if(!destroyed)raf=env.requestAnimationFrame(tick);};
  const set=value=>{position=Math.max(0,Math.min(duration,value));anchor=env.performance.now();paint();};
  raf=env.requestAnimationFrame(tick);
  return {
    getVideoUrl:()=>`https://replay.invalid/?v=${encodeURIComponent(videoId)}`,
    getCurrentTime:current,getDuration:()=>duration,getPlayerState:()=>current()>=duration?0:playing?1:2,
    getPlaybackRate:()=>rate,setPlaybackRate(value){set(current());rate=value;},
    getVolume:()=>0,isMuted:()=>false,setVolume(){},mute(){},unMute(){},
    playVideo(){set(current()>=duration?0:current());playing=true;onChange?.();},
    pauseVideo(){set(current());playing=false;onChange?.();},seekTo:set,
    destroy(){if(destroyed)return;destroyed=true;env.cancelAnimationFrame(raf);renderer.destroy();scene.remove();
      if(localEntry?.renderer===renderer)localEntry.renderer=null;},
  };
}
export default ReplayUpload;
