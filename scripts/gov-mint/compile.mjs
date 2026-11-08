import fs from 'node:fs';
import path from 'node:path';
import solc from 'solc';

export const root=path.resolve(import.meta.dirname,'../..');
export function compileGov(extraSources={}) {
  if(!solc.version().startsWith('0.8.28+'))throw Error('Exact solc 0.8.28 required');
  for(const name of ['@openzeppelin/contracts','@openzeppelin/contracts-upgradeable']){
    const p=JSON.parse(fs.readFileSync(path.join(root,'node_modules',name,'package.json'),'utf8'));
    if(p.version!=='5.1.0')throw Error(`${name} must be 5.1.0`);
  }
  const sources={...extraSources};
  for(const file of ['GOV MINT v2.sol','GOV MINT Sepolia v2.sol'])sources[file]={content:fs.readFileSync(path.join(root,file),'utf8')};
  const output=JSON.parse(solc.compile(JSON.stringify({language:'Solidity',sources,settings:{optimizer:{enabled:true,runs:200},evmVersion:'cancun',
    outputSelection:{'*':{'*':['abi','evm.bytecode.object','evm.deployedBytecode.object']}}}}),{import:name=>{
      const safe=name.replace(/@5\.1\.0\//g,'/');
      if(safe.includes('..'))return {error:'Unexpected parent import'};
      try{return {contents:fs.readFileSync(path.join(root,'node_modules',safe),'utf8')}}catch(e){return {error:e.message}}
  }}));
  const errors=(output.errors||[]).filter(x=>x.severity==='error');
  if(errors.length)throw Error(errors.map(x=>x.formattedMessage).join('\n'));
  for(const contracts of Object.values(output.contracts))for(const c of Object.values(contracts)){
    if(c.evm.deployedBytecode.object.length/2>24576)throw Error('Contract exceeds EIP-170');
  }
  return output.contracts;
}
