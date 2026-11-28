import { unzipSync, strFromU8 } from "fflate";
import manifest from '../../manifest.json';
export type AnimationFrames = string[];
export interface CharacterAnimations { [animationName:string]:AnimationFrames; }
export function fetchAnimations(id:number,cache:Map<number,Promise<CharacterAnimations>>,signal:AbortSignal):Promise<CharacterAnimations> {
 if(!cache.has(id))cache.set(id,load(manifest[characterZipUrlByExternalId[id]],signal));
 return cache.get(id)!;
}
const characterZipUrlByExternalId = [
  "captainFalcon.zip",
  "donkeyKong.zip",
  "fox.zip",
  "mrGameAndWatch.zip",
  "kirby.zip",
  "bowser.zip",
  "link.zip",
  "luigi.zip",
  "mario.zip",
  "marth.zip",
  "mewtwo.zip",
  "ness.zip",
  "peach.zip",
  "pikachu.zip",
  "iceClimbers.zip",
  "jigglypuff.zip",
  "samus.zip",
  "yoshi.zip",
  "zelda.zip",
  "sheik.zip",
  "falco.zip",
  "youngLink.zip",
  "doctorMario.zip",
  "roy.zip",
  "pichu.zip",
  "ganondorf.zip",
];


async function load(url:string,signal:AbortSignal):Promise<CharacterAnimations> {
 const response=await fetch(url,{signal,credentials:'same-origin'});
 if(!response.ok)throw Error('Character animations unavailable.');
 const buffers=unzipSync(new Uint8Array(await response.arrayBuffer()));
 if(signal.aborted)throw Error('Replay preparation cancelled.');
 return Object.fromEntries(Object.entries(buffers).map(([name,bytes])=>[name.replace('.json',''),JSON.parse(strFromU8(bytes))]));
}
