// Read-only preparation. Never loads a private key, signs, or broadcasts.
import fs from 'node:fs';
import path from 'node:path';
import solc from 'solc';
import {ethers} from 'ethers';

const root=path.resolve(import.meta.dirname,'..');
const [configPath,outputPath='artifacts/real-supply-oracle',implementation]=process.argv.slice(2);
if (!configPath || !process.env.RPC_URL) throw Error('Usage: RPC_URL=... node scripts/prepare-real-supply-oracle.mjs <config.json> [output-directory] [deployed-implementation]');
const config=JSON.parse(fs.readFileSync(path.resolve(configPath),'utf8'));
if (![1,11155111].includes(config.chainId)) throw Error('Unsupported chain ID');
const provider=new ethers.JsonRpcProvider(process.env.RPC_URL);
try {
  if ((await provider.getNetwork()).chainId!==BigInt(config.chainId)) throw Error('RPC network does not match config');
  const names=['owner','token','firstFactory','daoWallet','lpBurnAddress','rewardsReserveWallet','rewardsReserveSource'];
  for (const name of names) config[name]=ethers.getAddress(config[name]);
  if (config.owner===ethers.ZeroAddress) throw Error('Owner cannot be zero');
  const token=new ethers.Contract(config.token,['function decimals() view returns(uint8)','function totalSupply() view returns(uint256)'],provider);
  const block=await provider.getBlockNumber();
  if (await provider.getCode(config.token,block)==='0x') throw Error('Token has no code');
  if (await token.decimals({blockTag:block})!==18n) throw Error('Expected 18 decimals');
  const baseline=BigInt(config.issuedSupplyBaseline),live=await token.totalSupply({blockTag:block});
  if (baseline<live || baseline>ethers.parseEther('100000000')) throw Error('Invalid issuance baseline');
  if (config.firstFactory!==ethers.ZeroAddress) {
    const f=new ethers.Contract(config.firstFactory,['function realToken() view returns(address)','function totalLocked() view returns(uint256)','function getTotalDeployedContracts() view returns(uint256)'],provider);
    if ((await f.realToken({blockTag:block})).toLowerCase()!==config.token.toLowerCase()) throw Error('Wrong factory token');
    await f.totalLocked({blockTag:block});
    await f.getTotalDeployedContracts({blockTag:block});
  }
  const read=name=>fs.readFileSync(path.join(root,'node_modules',name.replace('@5.1.0/','/')),'utf8');
  const proxyName='@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';
  const input={language:'Solidity',sources:{'REALSupplyOracle.sol':{content:fs.readFileSync(path.join(root,'REALSupplyOracle.sol'),'utf8')},[proxyName]:{content:read(proxyName)}},settings:{optimizer:{enabled:true,runs:200},evmVersion:'cancun',outputSelection:{'*':{'*':['abi','evm.bytecode','evm.deployedBytecode','storageLayout','metadata']}}}};
  const output=JSON.parse(solc.compile(JSON.stringify(input),{import:name=>{try {const content=read(name);input.sources[name]={content};return {contents:content};} catch(error) {return {error:error.message};}}}));
  const errors=(output.errors||[]).filter(e=>e.severity==='error');
  if (errors.length) throw Error(errors.map(e=>e.formattedMessage).join('\n'));
  const oracle=output.contracts['REALSupplyOracle.sol'].REALSupplyOracle,proxy=output.contracts[proxyName].ERC1967Proxy;
  const initializer=new ethers.Interface(oracle.abi).encodeFunctionData('initialize',[config.owner,config.token,baseline,config.firstFactory,config.daoWallet,config.lpBurnAddress,config.voteExcludedWallets,config.rewardsReserveWallet,config.rewardsReserveSource]);
  const implementationTransaction={chainId:config.chainId,from:config.owner,value:'0x0',data:'0x'+oracle.evm.bytecode.object};
  const gas=await provider.estimateGas(implementationTransaction);
  const report={status:'UNSIGNED; nothing broadcast',contract:'REALSupplyOracle',config,block,compiler:solc.version(),initializer,estimatedImplementationGas:gas.toString(),implementationTransaction,proxyConstructor:{implementation:implementation||'REQUIRED_AFTER_IMPLEMENTATION_DEPLOYMENT',data:initializer}};
  if (implementation) {
    const address=ethers.getAddress(implementation);
    let expected=oracle.evm.deployedBytecode.object;
    const refs=Object.values(oracle.evm.deployedBytecode.immutableReferences);
    if (refs.length!==1) throw Error('Unexpected immutable layout; review before verification');
    for (const {start,length} of refs[0]) expected=expected.slice(0,start*2)+address.slice(2).toLowerCase().padStart(length*2,'0')+expected.slice((start+length)*2);
    if ((await provider.getCode(address,block)).toLowerCase()!=='0x'+expected.toLowerCase()) throw Error('Implementation bytecode does not match this build');
    report.proxyTransaction={chainId:config.chainId,from:config.owner,value:'0x0',data:'0x'+proxy.evm.bytecode.object+ethers.AbiCoder.defaultAbiCoder().encode(['address','bytes'],[address,initializer]).slice(2)};
    // This simulates the exact atomic initializer against live token/factory state.
    report.estimatedProxyGas=String(await provider.estimateGas(report.proxyTransaction));
  }
  const out=path.resolve(outputPath);fs.mkdirSync(out,{recursive:true});
  for (const [name,value] of Object.entries({'standard-input':input,'REALSupplyOracle-artifact':oracle,'ERC1967Proxy-artifact':proxy,'deployment-plan':report})) fs.writeFileSync(path.join(out,name+'.json'),JSON.stringify(value,null,2));
  fs.writeFileSync(path.join(out,'initializer.txt'),initializer);
  console.log(JSON.stringify({status:report.status,contract:report.contract,chainId:config.chainId,block,estimatedImplementationGas:report.estimatedImplementationGas,output:out},null,2));
} finally {provider.destroy();}
