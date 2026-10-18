// Read-only preparation for the reviewed REALSupplyOracle -> zero-LP upgrade.
// Usage: RPC_URL=... node scripts/prepare-lp-zero-upgrade.mjs <proxy> [new-implementation] [output-directory]
import fs from 'node:fs';
import path from 'node:path';
import solc from 'solc';
import {ethers} from 'ethers';
const root=path.resolve(import.meta.dirname,'..'),[proxyArg,newArg,outArg='artifacts/lp-zero-upgrade']=process.argv.slice(2);
if(!proxyArg||!process.env.RPC_URL)throw Error('Provide proxy address and RPC_URL');
const proxy=ethers.getAddress(proxyArg),p=new ethers.JsonRpcProvider(process.env.RPC_URL);
function compile(source){const input={language:'Solidity',sources:{'REALSupplyOracle.sol':{content:source}},settings:{optimizer:{enabled:true,runs:200},evmVersion:'cancun',outputSelection:{'*':{'*':['abi','evm.bytecode','evm.deployedBytecode','storageLayout']}}}};const output=JSON.parse(solc.compile(JSON.stringify(input),{import:n=>{try{const content=fs.readFileSync(path.join(root,'node_modules',n.replace('@5.1.0/','/')),'utf8');input.sources[n]={content};return{contents:content}}catch(e){return{error:e.message}}}}));if((output.errors||[]).some(e=>e.severity==='error'))throw Error(JSON.stringify(output.errors));return{input,artifact:output.contracts['REALSupplyOracle.sol'].REALSupplyOracle};}
function runtime(a,address){let code=a.evm.deployedBytecode.object;const refs=Object.values(a.evm.deployedBytecode.immutableReferences);if(refs.length!==1)throw Error('Unexpected immutable layout');for(const {start,length}of refs[0])code=code.slice(0,start*2)+address.slice(2).toLowerCase().padStart(length*2,'0')+code.slice((start+length)*2);return '0x'+code;}
try{
 const chainId=Number((await p.getNetwork()).chainId);if(![1,11155111].includes(chainId))throw Error('Unsupported network');
 const before=compile(fs.readFileSync(path.join(root,'test/fixtures/REALSupplyOracle.before-zero-lp.sol'),'utf8')),after=compile(fs.readFileSync(path.join(root,'REALSupplyOracle.sol'),'utf8'));
 const b=before.artifact.storageLayout,a=after.artifact.storageLayout;
 if(a.storage.length!==b.storage.length+1)throw Error('Unexpected storage additions');
 for(let i=0;i<b.storage.length;i++){const x=b.storage[i],y=a.storage[i];for(const k of ['label','slot','offset'])if(x[k]!==y[k])throw Error('Storage mismatch: '+k);if(b.types[x.type].label!==a.types[y.type].label||b.types[x.type].numberOfBytes!==a.types[y.type].numberOfBytes)throw Error('Storage type mismatch');}
 const block=await p.getBlockNumber(),slot='0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc',oldImpl=ethers.getAddress('0x'+(await p.getStorage(proxy,slot,block)).slice(-40));
 if((await p.getCode(oldImpl,block)).toLowerCase()!==runtime(before.artifact,oldImpl).toLowerCase())throw Error('Existing implementation does not match reviewed baseline. Stop and review target.');
 const oracle=new ethers.Contract(proxy,before.artifact.abi,p),owner=await oracle.owner({blockTag:block});if(owner===ethers.ZeroAddress)throw Error('Proxy owner is zero');
 const implementationTransaction={chainId,from:owner,value:'0x0',data:'0x'+after.artifact.evm.bytecode.object};
 const report={status:'UNSIGNED; no transactions sent',chainId,block,proxy,owner,previousImplementation:oldImpl,storageCompatible:true,implementationTransaction,estimatedImplementationGas:String(await p.estimateGas(implementationTransaction)),configurationData:new ethers.Interface(after.artifact.abi).encodeFunctionData('setLpBurnAddress',[ethers.ZeroAddress]),expectedCirculatingSupply:String(await oracle.getCirculatingSupply({blockTag:block}))};
 if(newArg){const address=ethers.getAddress(newArg);if((await p.getCode(address,block)).toLowerCase()!==runtime(after.artifact,address).toLowerCase())throw Error('New implementation bytecode mismatch');report.newImplementation=address;report.upgradeTransaction={chainId,from:owner,to:proxy,value:'0x0',data:new ethers.Interface(after.artifact.abi).encodeFunctionData('upgradeToAndCall',[address,report.configurationData])};report.estimatedUpgradeGas=String(await p.estimateGas(report.upgradeTransaction));}
 const out=path.resolve(outArg);fs.mkdirSync(out,{recursive:true});for(const [name,value]of Object.entries({'standard-input':after.input,'REALSupplyOracle-artifact':after.artifact,'upgrade-plan':report}))fs.writeFileSync(path.join(out,name+'.json'),JSON.stringify(value,null,2));
 console.log(JSON.stringify({status:report.status,chainId,proxy,owner,previousImplementation:oldImpl,storageCompatible:true,estimatedImplementationGas:report.estimatedImplementationGas,output:out},null,2));
}finally{p.destroy();}
