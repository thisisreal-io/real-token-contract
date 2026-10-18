import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import solc from 'solc';
import {ethers} from 'ethers';

const root=path.resolve(import.meta.dirname,'..');
const legacyName='test/fixtures/REALSupplyOracle.before-zero-lp.sol';
const proxyName='@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';
const read=n=>fs.readFileSync(path.join(root,'node_modules',n.replace('@5.1.0/','/')),'utf8');
const mocks=`pragma solidity ^0.8.28;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
contract Token is ERC20 {constructor() ERC20("REAL","REAL"){_mint(msg.sender,100000000 ether);}}
contract Factory {address public realToken;constructor(address t){realToken=t;}function totalLocked()external pure returns(uint256){return 500 ether;}function getTotalDeployedContracts()external pure returns(uint256){return 4;}}
contract Pair {address public token0;address public token1;uint256 public totalSupply;mapping(address=>uint256)public balanceOf;constructor(address t,address q){token0=t;token1=q;}function mint(address to,uint256 a)external{balanceOf[to]+=a;totalSupply+=a;}}
`;
const input={language:'Solidity',sources:{'REALSupplyOracle.sol':{content:fs.readFileSync(path.join(root,'REALSupplyOracle.sol'),'utf8')},[legacyName]:{content:fs.readFileSync(path.join(root,legacyName),'utf8')},[proxyName]:{content:read(proxyName)},'UpgradeMocks.sol':{content:mocks}},settings:{optimizer:{enabled:true,runs:200},evmVersion:'cancun',outputSelection:{'*':{'*':['abi','evm.bytecode.object','storageLayout']}}}};
const out=JSON.parse(solc.compile(JSON.stringify(input),{import:n=>{try{return {contents:read(n)}}catch(e){return {error:e.message}}}}));
assert.deepEqual((out.errors||[]).filter(e=>e.severity==='error'),[]);
const old=out.contracts[legacyName].REALSupplyOracle,current=out.contracts['REALSupplyOracle.sol'].REALSupplyOracle;
// Preserve every legacy slot, byte offset and type. Appending a bool can use
// unused bytes after the last address without changing that address's storage.
const describe=(a,v)=>({label:v.label,slot:v.slot,offset:v.offset,type:a.storageLayout.types[v.type].label,bytes:a.storageLayout.types[v.type].numberOfBytes});
assert.equal(current.storageLayout.storage.length,old.storageLayout.storage.length+1);
old.storageLayout.storage.forEach((v,i)=>assert.deepEqual(describe(current,current.storageLayout.storage[i]),describe(old,v)));
assert.equal(current.storageLayout.storage.at(-1).label,'_lpBurnAddressConfigured');
console.log('PASS: every existing storage slot, offset and type is preserved; flag is appended');

const p=new ethers.JsonRpcProvider(process.env.REAL_ORACLE_TEST_RPC||'http://127.0.0.1:18548');
try {
assert.equal((await p.getNetwork()).chainId,31337n);
const [admin,attacker,dao,reserve,quote,burn]=await Promise.all(Array.from({length:6},(_,i)=>p.getSigner(i)));
const addr=s=>s.getAddress(),tx=async q=>{await(await q).wait()};
async function deploy(a,args=[]){const c=await new ethers.ContractFactory(a.abi,a.evm.bytecode.object,admin).deploy(...args);await c.waitForDeployment();return c;}
const token=await deploy(out.contracts['UpgradeMocks.sol'].Token),factory=await deploy(out.contracts['UpgradeMocks.sol'].Factory,[await token.getAddress()]);
const pair=await deploy(out.contracts['UpgradeMocks.sol'].Pair,[await token.getAddress(),await addr(quote)]);
await tx(pair.mint(ethers.ZeroAddress,1000n));await tx(pair.mint(await addr(burn),500n));
await tx(token.transfer(await addr(dao),ethers.parseEther('1000')));await tx(token.transfer(await addr(reserve),ethers.parseEther('100')));
const oldImpl=await deploy(old),newImpl=await deploy(current);
const slot='0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';
for (const legacyBurn of [ethers.ZeroAddress,await addr(burn)]) {
  const snapshot=await p.send('evm_snapshot',[]);
  const args=[await addr(admin),await token.getAddress(),ethers.parseEther('100000000'),await factory.getAddress(),await addr(dao),ethers.ZeroAddress,[await addr(attacker)],await addr(reserve),ethers.ZeroAddress];
  args[5]=legacyBurn;
  const init=new ethers.Interface(old.abi).encodeFunctionData('initialize',args);
  const proxy=await deploy(out.contracts[proxyName].ERC1967Proxy,[await oldImpl.getAddress(),init]);
  const legacy=new ethers.Contract(await proxy.getAddress(),old.abi,admin);
  await tx(legacy.setEthLpPair(await pair.getAddress(),await addr(quote)));
  await tx(legacy.transferOwnership(await addr(attacker)));
  const fields=['owner','pendingOwner','realToken','issuedSupplyBaseline','vestingFactory','daoWallet','lpBurnAddress','rewardsReserveWallet','rewardsReserveSource','stakingMetricsSource','getCirculatingSupply','getNonCirculatingBalance','getEthLpTotalSupply','getFactoryCount','getVoteExcludedWallets','getVestingFactories'];
  const normalize=v=>Array.isArray(v)?Array.from(v):v;
  const before=(await Promise.all(fields.map(n=>legacy[n]()))).map(normalize);
  await assert.rejects(legacy.connect(attacker).upgradeToAndCall.staticCall(await newImpl.getAddress(),'0x'));
  await tx(legacy.upgradeToAndCall(await newImpl.getAddress(),'0x'));
  const oracle=new ethers.Contract(await proxy.getAddress(),current.abi,admin);
  assert.deepEqual((await Promise.all(fields.map(n=>oracle[n]()))).map(normalize),before);
  assert.equal(await p.getStorage(await proxy.getAddress(),slot),ethers.zeroPadValue(await newImpl.getAddress(),32).toLowerCase());
  assert.equal(await oracle.isLpBurnAddressConfigured(),legacyBurn!==ethers.ZeroAddress);
  assert.equal(await oracle.getEthLpBurned(),legacyBurn===ethers.ZeroAddress?0n:500n);
  await assert.rejects(oracle.connect(attacker).setLpBurnAddress.staticCall(ethers.ZeroAddress));
  await assert.rejects(oracle.connect(attacker).clearLpBurnAddress.staticCall());
  // Owner can activate zero-address tracking in the same transaction as upgrade.
  await tx(oracle.upgradeToAndCall(await newImpl.getAddress(),oracle.interface.encodeFunctionData('setLpBurnAddress',[ethers.ZeroAddress])));
  assert.equal(await oracle.isLpBurnAddressConfigured(),true);
  assert.equal(await oracle.lpBurnAddress(),ethers.ZeroAddress);
  assert.equal(await oracle.getEthLpBurned(),1000n);
  assert.equal(await oracle.getUsdcLpBurned(),0n,'unconfigured pair reports zero');
  await tx(oracle.setUsdcLpPair(ethers.ZeroAddress,ethers.ZeroAddress));
  await tx(pair.mint(ethers.ZeroAddress,2000n));
  assert.equal(await oracle.getEthLpBurned(),3000n);
  assert.equal(await oracle.getCirculatingSupply(),before[10]);
  await tx(oracle.clearLpBurnAddress());assert.equal(await oracle.isLpBurnAddressConfigured(),false);assert.equal(await oracle.getEthLpBurned(),0n);
  await tx(oracle.setLpBurnAddress(await addr(burn)));assert.equal(await oracle.getEthLpBurned(),500n);
  await assert.rejects(oracle.initialize.staticCall(...args));
  await assert.rejects(newImpl.initialize.staticCall(...args));
  console.log('PASS: legacy '+(legacyBurn===ethers.ZeroAddress?'unset':'nonzero')+' configuration upgraded; settings, authority, zero-address activation, clearing and circulation preserved');
  assert.equal(await p.send('evm_revert',[snapshot]),true);
}
} finally {p.destroy();}
