// Deterministic, pinned bundles. --check verifies committed artifacts without writes.
import {build} from 'esbuild';
import {transformAsync} from '@babel/core';
import fs from 'node:fs/promises';
import {createHash} from 'node:crypto';
const check=process.argv.includes('--check');
const provenance=JSON.parse(await fs.readFile('provenance.json','utf8'));
if(provenance.revision!=='ba4e09172344d1e7957de2d8a6eebab31632d92f')throw Error('Unexpected upstream revision');
const common={bundle:true,write:false,format:'esm',platform:'browser',conditions:['browser'],alias:{util:'./src/encoding.ts'},target:'es2022',minify:true,legalComments:'eof',tsconfig:'tsconfig.json'};
const worker=(await build({...common,entryPoints:['src/worker.ts'],outfile:'worker.mjs'})).outputFiles[0].contents;
const hash=b=>createHash('sha256').update(b).digest('hex').slice(0,16);
const manifest={'worker.mjs':`/assets/slippi/worker-${hash(worker)}.mjs`};
for(const name of (await fs.readdir('zips')).filter(n=>n.endsWith('.zip')).sort()){
 const bytes=await fs.readFile('zips/'+name);
 const record=provenance.assets.find(a=>a.file==='zips/'+name);
 if(!record||record.sha256!==createHash('sha256').update(bytes).digest('hex'))throw Error('Pinned archive mismatch: '+name);
 manifest[name]=`/assets/slippi/${name.replace('.zip','')}-${hash(bytes)}.zip`;
}
const manifestText=JSON.stringify(manifest,null,2)+'\n';
const solid={name:'solid',setup(build){
 build.onLoad({filter:/manifest\.json$/},()=>({contents:manifestText,loader:'json'}));
 build.onLoad({filter:/\.tsx$/},async({path})=>{
  const result=await transformAsync(await fs.readFile(path,'utf8'),{filename:path,presets:[['babel-preset-solid',{generate:'dom'}],['@babel/preset-typescript',{isTSX:true,allExtensions:true}]]});
  return {contents:result.code,loader:'js'};
 });
}};
// Resolution needs the committed manifest path to exist on an initial checkout.
const runtime=(await build({...common,entryPoints:['src/entry.tsx'],outfile:'runtime.mjs',plugins:[solid]})).outputFiles[0].contents;
let notices='SlippiLab-derived approximate replay viewer\nSource: '+provenance.repository+'/tree/'+provenance.revision+'\nCharacter archive provenance: provenance.json\n\n'+await fs.readFile('LICENSE','utf8');
for(const name of (await fs.readdir('licenses')).sort())notices+='\n\n'+name+'\n'+await fs.readFile('licenses/'+name,'utf8');
for(const [name,bytes] of [['worker.mjs',worker],['runtime.mjs',runtime],['manifest.json',Buffer.from(manifestText)],['NOTICES.txt',Buffer.from(notices)]]){
 if(check){if(!Buffer.from(await fs.readFile(name)).equals(Buffer.from(bytes)))throw Error(`Rebuild stale Slippi artifact: ${name}`);}
 else await fs.writeFile(name,bytes);
}
