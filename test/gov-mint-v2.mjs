import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import solc from 'solc';
import {ethers} from 'ethers';
import {treeFor} from '../scripts/gov-mint/build-electorate.mjs';

const root=path.resolve(import.meta.dirname,'..');
const source=fs.readFileSync(path.join(root,'GOV MINT v2.sol'),'utf8');
const mocks=`// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
contract GovTestToken is ERC20 {
 constructor() ERC20("Test REAL","REAL") {_mint(msg.sender,100_000_000 ether);}
}
contract GovTestOracle {
 uint256 public supply=1_000_000 ether;
 mapping(address=>bool) public excluded;
 function setSupply(uint256 value) external {supply=value;}
 function setExcluded(address wallet,bool value) external {excluded[wallet]=value;}
 function getCirculatingSupply() external view returns(uint256) {return supply;}
 function isVotingExcluded(address wallet) external view returns(bool) {return excluded[wallet];}
}`;
function readImport(name) {
 return fs.readFileSync(path.join(root,'node_modules',name.replace(/@5\.1\.0\//g,'/')),'utf8');
}
const input={language:'Solidity',sources:{'GOV MINT v2.sol':{content:source},'GovMocks.sol':{content:mocks},'@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol':{content:readImport('@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol')}},settings:{optimizer:{enabled:true,runs:200},evmVersion:'cancun',outputSelection:{'*':{'*':['abi','evm.bytecode.object','evm.deployedBytecode.object']}}}};
const compiled=JSON.parse(solc.compile(JSON.stringify(input),{import:name=>{try{return {contents:readImport(name)}}catch(e){return {error:e.message}}}}));
assert.deepEqual((compiled.errors||[]).filter(x=>x.severity==='error'),[]);
for(const warning of compiled.errors||[]) console.error(warning.formattedMessage);
const artifact=(file,name)=>compiled.contracts[file][name];
const byteSize=artifact('GOV MINT v2.sol','GOVMINTv2').evm.deployedBytecode.object.length/2;
assert(byteSize<24576,'implementation must fit EIP-170');
console.log(`Compiled Solidity 0.8.28 / OpenZeppelin 5.1.0; runtime ${byteSize} bytes`);
const provider=new ethers.JsonRpcProvider(process.env.GOV_MINT_TEST_RPC||'http://127.0.0.1:18549',undefined,{cacheTimeout:-1});
assert.equal((await provider.getNetwork()).chainId,31337n,'local chain only');
const accounts=await Promise.all(Array.from({length:20},(_,i)=>provider.getSigner(i)));
const addresses=await Promise.all(accounts.map(x=>x.getAddress()));
let checks=0;
function ok(name){checks++;console.log(`PASS ${checks}: ${name}`)}
async function deploy(file,name,args=[]) {const a=artifact(file,name);const c=await new ethers.ContractFactory(a.abi,a.evm.bytecode.object,accounts[0]).deploy(...args);await c.waitForDeployment();return c;}
async function tx(p){await (await p).wait();}
async function reverts(p){await assert.rejects(async()=>{const r=await p;if(r?.wait)await r.wait()});}
const day=86400;
async function now(){return Number((await provider.send('eth_getBlockByNumber',['latest',false])).timestamp);}
async function at(time){await provider.send('evm_setNextBlockTimestamp',[time]);await provider.send('evm_mine',[]);}
const token=await deploy('GovMocks.sol','GovTestToken');
const oracle=await deploy('GovMocks.sol','GovTestOracle');
const implementation=await deploy('GOV MINT v2.sol','GOVMINTv2');
const abi=artifact('GOV MINT v2.sol','GOVMINTv2').abi;
const iface=new ethers.Interface(abi);
async function makeDao(signers=addresses.slice(0,5),tokenAddress=null,oracleAddress=null) {
 tokenAddress ??= await token.getAddress(); oracleAddress ??= await oracle.getAddress();
 const data=iface.encodeFunctionData('initialize',[tokenAddress,oracleAddress,signers]);
 const proxy=await deploy('@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol','ERC1967Proxy',[await implementation.getAddress(),data]);
 const dao=new ethers.Contract(await proxy.getAddress(),abi,accounts[0]);
 await tx(token.transfer(await dao.getAddress(),ethers.parseEther('4000000')));
 return dao;
}
await reverts(makeDao([addresses[0],addresses[0],...addresses.slice(2,5)]));
await reverts(makeDao([ethers.ZeroAddress,...addresses.slice(1,5)]));
await reverts(makeDao(addresses.slice(0,5),addresses[0]));
await reverts(makeDao(addresses.slice(0,5),await token.getAddress(),addresses[0]));
ok('initialization rejects zero/duplicate signers and non-contract token/oracle addresses');
const dao=await makeDao();
await reverts(dao.initialize(await token.getAddress(),await oracle.getAddress(),addresses.slice(0,5)));
await reverts(implementation.initialize(await token.getAddress(),await oracle.getAddress(),addresses.slice(0,5)));
assert(!abi.some(x=>x.name==='upgradeToAndCall'));
await reverts(accounts[0].sendTransaction({to:await dao.getAddress(),data:new ethers.Interface(['function upgradeToAndCall(address,bytes)']).encodeFunctionData('upgradeToAndCall',[await implementation.getAddress(),'0x'])}));
assert(!abi.some(x=>x.name==='updateAuthorizedWallet'||x.name==='updateSupplyOracle'));
ok('reinitialization, implementation initialization and deployer upgrade are blocked; unilateral setters absent');

const voters=addresses.slice(5,15);
const proofSets=new Map();
function proof(p,index){return proofSets.get(p.key)[index];}
async function propose(contract=dao,amount=ethers.parseEther('1000000'),singleWallet=null,walletCount=10,totalVotingPower=200) {
 const id=Number(await contract.proposalCount()),start=(await now())+day,end=start+day;
 const block=await provider.getBlock('latest');
 const context={chainId:31337,dao:await contract.getAddress(),token:await token.getAddress(),snapshotBlock:block.number,snapshotHash:block.hash};
 const entries=(singleWallet?[singleWallet]:voters).map(wallet=>({wallet,power:20}));
 const tree=treeFor(context,entries);
 const electorate={walletCount,totalVotingPower,circulatingSupply:await oracle.getCirculatingSupply(),snapshotBlock:block.number,snapshotHash:block.hash,manifestHash:ethers.id('local test manifest')};
 await tx(contract.createProposal(addresses[19],amount,tree.root,electorate));
 const key=`${await contract.getAddress()}:${id}`;proofSets.set(key,tree.proofs);
 return {id,start,end,key};
}
const first=await propose(),second=await propose();
await reverts(dao.connect(accounts[5]).approveProposal(first.id));
await reverts(dao.approveProposal(first.id));
await tx(dao.connect(accounts[1]).approveProposal(first.id));
assert.equal(await dao.proposalApprovalCount(first.id),2n);
const snapshot=await provider.send('evm_snapshot',[]);
await at(first.start);
await reverts(dao.connect(accounts[5]).castVote(first.id,true,20,proof(first,0)));
assert.equal(await dao.getProposalStatus(first.id),2n);
await provider.send('evm_revert',[snapshot]);
ok('creator counts once, outsiders/duplicates rejected; two approvals never open voting');
for(const p of [first,second]){
 if(p===second)await tx(dao.connect(accounts[1]).approveProposal(p.id));
 await tx(dao.connect(accounts[2]).approveProposal(p.id));
 assert.equal((await dao.getProposalDetails(p.id)).votingStart,BigInt(await now()),"vote starts at third approval timestamp");
}
for (const p of [first,second]) {
 const details=await dao.getProposalDetails(p.id);
 assert.equal(details.votingEnd-details.votingStart,30n*BigInt(day));
 p.start=Number(details.votingStart); p.end=Number(details.votingEnd);
}
assert.equal(await dao.HOLDING_PERIOD(),30n*BigInt(day));
await reverts(dao.connect(accounts[3]).approveProposal(first.id));
await reverts(dao.castVote(first.id,true,20,[]));
await reverts(dao.connect(accounts[5]).castVote(999,true,20,proof(first,0)));
await reverts(dao.connect(accounts[5]).castVote(first.id,true,21,proof(first,0)));
await tx(oracle.setExcluded(addresses[5],true));
await reverts(dao.connect(accounts[5]).castVote(first.id,true,20,proof(first,0)));
await tx(oracle.setExcluded(addresses[5],false));
for(const p of [first,second])for(let i=0;i<10;i++)await tx(dao.connect(accounts[i+5]).castVote(p.id,true,20,proof(p,i)));
await reverts(dao.connect(accounts[5]).castVote(first.id,true,20,proof(first,0)));
ok('three approvals open voting; signer, invalid proposal/proof, excluded wallet and duplicate votes rejected');
await reverts(dao.executeProposal(first.id));
await at(Math.max(first.end,second.end)+30*day);
const oldBalance=await token.balanceOf(addresses[19]);
await tx(dao.connect(accounts[18]).executeProposal(first.id));
assert.equal((await token.balanceOf(addresses[19]))-oldBalance,ethers.parseEther('1000000'));
const releaseTime=Number(await dao.lastApprovalTimestamp());
assert.equal(await dao.getTimeUntilExecution(second.id),90n*BigInt(day));
assert(releaseTime>first.end);
assert.equal(await dao.totalReleased(),ethers.parseEther('1000000'));
await reverts(dao.executeProposal(second.id));
await at(releaseTime+90*day-1);
await reverts(dao.executeProposal.staticCall(second.id));
await at(releaseTime+90*day);
await tx(dao.executeProposal(second.id));
await reverts(dao.executeProposal(first.id));
ok('timelock, permissionless execution, exact amount, replay protection and 90 days between actual transfers');

// Recovery tests on a separate instance, with an active old-epoch proposal.
const recovery=await makeDao();
const pending=await propose(recovery);
await tx(recovery.connect(accounts[1]).approveProposal(pending.id));
await tx(recovery.connect(accounts[2]).approveProposal(pending.id));
const nonce=ethers.id('pause-before-rotation');
await tx(recovery.signPauseSystem(nonce));
await reverts(recovery.requestWalletReplacement(5,addresses[15]));
await reverts(recovery.requestWalletReplacement(4,ethers.ZeroAddress));
await reverts(recovery.requestWalletReplacement(4,addresses[3]));
await tx(recovery.requestWalletReplacement(4,addresses[15]));
await reverts(recovery.approveWalletReplacement(0));
await reverts(recovery.connect(accounts[15]).approveWalletReplacement(0));
await tx(recovery.connect(accounts[1]).approveWalletReplacement(0));
assert.equal(await recovery.authorizedWallets(4),addresses[4]);
await tx(recovery.connect(accounts[2]).approveWalletReplacement(0));
assert.equal(await recovery.authorizedWallets(4),addresses[15]);
assert.equal(await recovery.signerEpoch(),1n);
await reverts(recovery.connect(accounts[4]).requestWalletReplacement(0,addresses[16]));
await reverts(recovery.connect(accounts[1]).approveWalletReplacement(0));
await reverts(recovery.approveProposal(pending.id));
await reverts(recovery.executeProposal(pending.id));
ok('request plus two current approvals atomically replaces one wallet; nominee, removed signer, duplicates and stale requests blocked');
await tx(recovery.connect(accounts[1]).signPauseSystem(nonce));
await tx(recovery.connect(accounts[2]).signPauseSystem(nonce));
assert.equal(await recovery.systemPaused(),false);
await tx(recovery.connect(accounts[15]).signPauseSystem(nonce));
assert.equal(await recovery.systemPaused(),true);
ok('pre-rotation emergency signatures cannot combine with the new signer group');
await tx(recovery.requestWalletReplacement(3,addresses[16]));
await tx(recovery.connect(accounts[1]).approveWalletReplacement(1));
await tx(recovery.connect(accounts[2]).approveWalletReplacement(1));
assert.equal(await recovery.authorizedWallets(3),addresses[16]);
assert.equal(await recovery.systemPaused(),true);
await reverts(recovery.connect(accounts[3]).signUnpauseSystem(ethers.id('unpause')));
for(let i=0;i<3;i++)await tx(recovery.connect(accounts[i]).signUnpauseSystem(ethers.id('unpause')));
assert.equal(await recovery.systemPaused(),false);
ok('wallet recovery works during emergency pause; only the current group can unpause');

// Emergency approvals are bound to a pause-state revision as well as a signer epoch.
const staleNonce=ethers.id('old-partial-pause');
await reverts(recovery.signUnpauseSystem(ethers.id('preapproved-unpause')));
await tx(recovery.signPauseSystem(staleNonce));
for(let i=0;i<3;i++)await tx(recovery.connect(accounts[i]).signPauseSystem(ethers.id('different-pause')));
for(let i=0;i<3;i++)await tx(recovery.connect(accounts[i]).signUnpauseSystem(ethers.id('fresh-unpause')));
await tx(recovery.connect(accounts[1]).signPauseSystem(staleNonce));
await tx(recovery.connect(accounts[2]).signPauseSystem(staleNonce));
assert.equal(await recovery.systemPaused(),false,'old-cycle signature must not count');
await tx(recovery.signPauseSystem(staleNonce));
assert.equal(await recovery.systemPaused(),true);
for(let i=0;i<3;i++)await tx(recovery.connect(accounts[i]).signUnpauseSystem(ethers.id('finish-unpause')));
ok('opposite-state preapprovals rejected; partial approvals cannot survive a full pause/unpause cycle');

await tx(oracle.setSupply(ethers.parseEther('1000001')));
const rounded=await propose(recovery);
assert.equal(await recovery.getQuorumThreshold(rounded.id),1n,'quorum is 2% of eligible addresses, rounded up');
for(let i=1;i<3;i++)await tx(recovery.connect(accounts[i]).approveProposal(rounded.id));
for(let i=0;i<3;i++)await tx(recovery.connect(accounts[i]).signPauseProposal(rounded.id,ethers.id('proposal-pause')));
assert.equal(await recovery.getProposalStatus(rounded.id),7n,'paused state exposed');
await reverts(recovery.signPauseProposal(pending.id,ethers.id('obsolete-proposal')));
for(let i=0;i<3;i++)await tx(recovery.connect(accounts[i]).signUnpauseProposal(rounded.id,ethers.id('proposal-unpause')));
assert.equal(await recovery.getProposalStatus(rounded.id),1n);
ok('quorum rounds upward consistently; paused proposal status is visible and obsolete proposals cannot be paused');

const retiredLeaf=ethers.solidityPackedKeccak256(['address','uint256'],[addresses[4],20]);
const retired=await propose(recovery,ethers.parseEther('1000000'),addresses[4]);
for(let i=1;i<3;i++)await tx(recovery.connect(accounts[i]).approveProposal(retired.id));
await at(retired.start);
assert.equal(await oracle.isVotingExcluded(addresses[4]),false,'mock oracle deliberately misses retired corporate wallet');
assert.equal(await recovery.corporateWallet(addresses[4]),true);
await reverts(recovery.connect(accounts[4]).castVote(retired.id,true,20,[]));
ok('removed corporate signer cannot become a public voter even if the oracle omits it and the Merkle proof is valid');

await tx(oracle.setSupply(0));
await reverts(propose(recovery));
await tx(oracle.setSupply(ethers.parseEther('100000001')));
await reverts(propose(recovery));
await tx(oracle.setSupply(ethers.parseEther('10000')));
const tiny=await propose(recovery,ethers.parseEther('1000000'),null,10,10);
await tx(recovery.connect(accounts[1]).approveProposal(tiny.id));
await tx(recovery.connect(accounts[2]).approveProposal(tiny.id));
await at(tiny.start);
await reverts(recovery.connect(accounts[5]).castVote(tiny.id,true,20,proof(tiny,0)));
ok('zero/oversized supply snapshots and zero-effective-power votes rejected');
console.log(`${checks} integration groups passed. DRAFT: Merkle ownership is NOT verified by these contracts; no live RPC or deployment used.`);
await provider.destroy();
