import {createMemo,For} from 'solid-js';
import {render} from 'solid-js/web';
import {useReplayStore,createReplayState,ReplayContext} from './state/replayStore';
import {fetchAnimations} from './viewer/animationCache';
import {characterNameByExternalId,characterNameByInternalId} from './common/ids';
import {Stage} from './components/viewer/Stage';
import {Players} from './components/viewer/Player';
import {HUD} from './components/viewer/HUD';
import {Item} from './components/viewer/Item';
function Viewer() {
 const camera=createMemo(()=>{
  const players=useReplayStore().replayData!.frames[useReplayStore().frame].players.filter(Boolean);
  const xs=players.map(p=>p.state.xPosition),ys=players.map(p=>p.state.yPosition);
  const x=(Math.min(...xs)+Math.max(...xs))/2,y=(Math.min(...ys)+Math.max(...ys))/2;
  const scale=Math.min(640/Math.max(150,Math.max(...xs)-Math.min(...xs)+70),430/Math.max(120,Math.max(...ys)-Math.min(...ys)+70));
  return `scale(${scale}) translate(${-x},${-y})`;
 });
 return <svg id="slippi-scene" role="img" aria-label="Approximate Slippi replay visualization" viewBox="-365 -300 730 600" style="width:100%;height:100%;background:#f8fafc">
  <g transform="scale(1,-1)"><g transform={camera()}><Stage/><Players/><For each={useReplayStore().replayData!.frames[useReplayStore().frame].items}>{item=><Item item={item}/>}</For></g><HUD/></g>
 </svg>;
}
export async function mount(host:HTMLElement,replay:any,signal?:AbortSignal) {
 const controller=new AbortController();
 const abort=()=>controller.abort();
 signal?.addEventListener('abort',abort,{once:true});
 if(signal?.aborted)controller.abort();
 const ids=new Set<number>();
 for(const frame of replay.frames) for(const player of frame.players.filter(Boolean)) {
  ids.add(player.state.internalCharacterId);
  if(player.nanaState) ids.add(player.nanaState.internalCharacterId);
 }
 const animations:any[]=[],cache=new Map();
 try {
  await Promise.all([...ids].map(async id=>{
   const external=id===10||id===11?14:characterNameByExternalId.indexOf(characterNameByInternalId[id]);
   if(external<0)throw Error('Unsupported character.');
   animations[id]=await fetchAnimations(external,cache,controller.signal);
  }));
  if(controller.signal.aborted)throw Error('Replay preparation cancelled.');
  const state=createReplayState(replay,animations);
  state.showFrame(0);
  const dispose=render(()=><ReplayContext.Provider value={state.store}><Viewer/></ReplayContext.Provider>,host);
  let destroyed=false;
  return {frame:(n:number)=>{if(!destroyed)state.showFrame(n);},destroy(){
   if(destroyed)return;destroyed=true;controller.abort();dispose();state.clear();cache.clear();
   signal?.removeEventListener('abort',abort);
  }};
 } catch(error) {controller.abort();cache.clear();signal?.removeEventListener('abort',abort);throw error;}
}
