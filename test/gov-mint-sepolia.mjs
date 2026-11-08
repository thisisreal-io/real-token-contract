import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {ethers} from 'ethers';
import {compileGov,root} from '../scripts/gov-mint/compile.mjs';
import {minimumBalances,buildElectorate,treeFor,voteLeaf} from '../scripts/gov-mint/build-electorate.mjs';
import {prepareSepolia} from '../scripts/gov-mint/prepare-sepolia.mjs';

const proxyFile='@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';
const fixtureFile='GOV MINT Test Fixtures.sol';
const contracts=compileGov({[proxyFile]:{content:fs.readFileSync(path.join(root,'node_modules',proxyFile),'utf8')},
  [fixtureFile]:{content:fs.readFileSync(path.join(root,fixtureFile),'utf8')}});
const govArtifact=contracts['GOV MINT Sepolia v2.sol'].GOVMINTSepoliaV2;
const provider=new ethers.JsonRpcProvider(process.env.GOV_MINT_TEST_RPC||'http://127.0.0.1:18549',undefined,{cacheTimeout:-1});
assert.equal((await provider.getNetwork()).chainId,31337n,'tests use only local chain');
const signers=await Promise.all(Array.from({length:20},(_,i)=>provider.getSigner(i)));
const addresses=await Promise.all(signers.map(s=>s.getAddress()));
const units=x=>ethers.parseEther(String(x));
let groups=0;const pass=name=>console.log(`PASS ${++groups}: ${name}`);
const tx=async p=>(await p).wait();
async function rejects(p){await assert.rejects(async()=>{const r=await p;if(r?.wait)await r.wait()});}
const now=async()=>Number((await provider.send('eth_getBlockByNumber',['latest',false])).timestamp);
async function advance(seconds){await provider.send('evm_increaseTime',[seconds]);await provider.send('evm_mine',[]);}
async function at(timestamp){await provider.send('evm_setNextBlockTimestamp',[Number(timestamp)]);await provider.send('evm_mine',[]);}
async function deploy(file,name,args=[]){const a=contracts[file][name],c=await new ethers.ContractFactory(a.abi,a.evm.bytecode.object,signers[0]).deploy(...args);await c.waitForDeployment();return c;}
const token=await deploy(fixtureFile,'GOVMINTTestREAL');
const tokenReceipt=await token.deploymentTransaction().wait();
const oracle=await deploy(fixtureFile,'GOVMINTTestOracle',[await token.getAddress()]);
const config={chainId:31337,deployer:addresses[0],token:await token.getAddress(),oracle:await oracle.getAddress(),authorizedWallets:addresses.slice(0,5)};
await rejects(prepareSepolia(provider,config));
await rejects(prepareSepolia(provider,{...config,authorizedWallets:[addresses[0],addresses[0],...addresses.slice(2,5)]},{local:true}));
const plan=await prepareSepolia(provider,config,{local:true});
assert.equal(await provider.getCode(plan.implementation),'0x','preparation must not deploy');
assert.equal(plan.status,'UNSIGNED_SEPOLIA_TEST_PLAN');
assert(plan.abi.some(x=>x.name==='castVote'));
assert.equal(plan.proxyConstructorArguments[0],plan.implementation);
for(const unsigned of plan.transactions)await tx(signers[0].sendTransaction({...unsigned,chainId:BigInt(unsigned.chainId),value:0n}));
const dao=new ethers.Contract(plan.dao,govArtifact.abi,signers[0]);
assert.deepEqual([...(await dao.timingConfiguration())],[108000n,108000n,108000n,324000n,5n]);
assert.equal(await dao.realToken(),await token.getAddress());
assert.equal(await dao.supplyOracle(),await oracle.getAddress());
await rejects(dao.initialize(await token.getAddress(),await oracle.getAddress(),addresses.slice(0,5)));
pass('unsigned deployment preparation, network guards, distinct signers and atomic fixed-proxy initialization');

await tx(oracle.setDao(plan.dao));
await tx(token.transfer(plan.dao,units(4000000)));
for(let i=5;i<10;i++)await tx(token.transfer(addresses[i],units(20000)));
await tx(token.transfer(addresses[10],units(5000)));
await tx(token.transfer(addresses[11],units(1000)));
await tx(token.transfer(addresses[12],units(5000)));
await tx(token.transfer(addresses[14],units(999)));
await tx(token.transfer(await oracle.getAddress(),units(10000)));
const initialTime=await now();
await advance(15*3600);
await tx(token.connect(signers[10]).transfer(addresses[15],units(3000)));
await tx(token.connect(signers[15]).transfer(addresses[10],units(3000)));
await tx(token.transfer(addresses[11],units(1000)));
await tx(token.connect(signers[12]).transfer(addresses[13],units(5000)));
await tx(token.connect(signers[13]).transfer(addresses[12],units(5000)));
await tx(token.connect(signers[9]).burn(units(1000)));
await at(initialTime+30*3600+60);
const scanConfig={dao:plan.dao,token:await token.getAddress(),tokenDeploymentBlock:tokenReceipt.blockNumber,excludedWallets:[],logBlockRange:5};
await provider.send('evm_mine',[]);await provider.send('evm_mine',[]);
await rejects(buildElectorate(provider,{...scanConfig,tokenDeploymentBlock:null}));
const scan=await buildElectorate(provider,scanConfig);
const entry=i=>scan.payload.entries.find(e=>e.wallet===addresses[i]);
assert.equal(entry(10).power,'2','moved and returned 5000 retains only its 2000 minimum');
assert.equal(entry(11).power,'1','recent top-up does not count');
assert.equal(entry(9).power,'19','burn reduces eligible balance');
assert.equal(entry(12),undefined,'zero minimum disqualifies moved-and-returned balance');
assert.equal(entry(13),undefined,'recipient lacked opening balance');
assert.equal(entry(14),undefined,'999 tokens cannot count as eligible wallet');
assert.equal(entry(0),undefined,'corporate tokens excluded');
assert.equal(scan.payload.entries.some(e=>e.wallet===plan.dao),false,'DAO reserve excluded');
assert.equal(scan.payload.entries.some(e=>e.wallet===config.oracle),false,'system contract excluded');
assert.equal(scan.payload.eligibleWalletCount,7);
assert.equal(scan.payload.totalVotingPower,'102');
const repeat=await buildElectorate(provider,{...scanConfig,snapshotBlock:scan.payload.snapshotBlock});
assert.equal(repeat.merkleRoot,scan.merkleRoot);assert.equal(repeat.manifestHash,scan.manifestHash);
pass('full-history scanner: minima, returned tokens, top-ups, burns, sub-1000, corporate/system exclusions and reproducibility');

const a=addresses[5],b=addresses[6];
const log=(from,to,value,index)=>({from,to,value,blockNumber:1,transactionIndex:0,index});
const start=new Map([[a,5000n],[b,0n]]);
const history=[log(a,b,5000n,0),log(b,a,5000n,1)];
assert.equal(minimumBalances(start,history).minimum.get(a.toLowerCase()),0n);
assert.throws(()=>minimumBalances(start,[history[1],history[0]]));
assert.throws(()=>minimumBalances(start,[history[0],history[0]]));
assert.throws(()=>minimumBalances(start,[log(a,b,5001n,0)]));
assert.equal(minimumBalances(start,[log(a,a,5000n,0)]).minimum.get(a.toLowerCase()),5000n);
assert.notEqual(voteLeaf(scan.payload,a,20),voteLeaf({...scan.payload,chainId:1},a,20));
assert.notEqual(voteLeaf(scan.payload,a,20),voteLeaf({...scan.payload,dao:addresses[18]},a,20));
pass('history replay rejects duplicate/out-of-order/impossible events; self-transfer handled; proof domains bind chain and DAO');

const recipient=addresses[19];
async function create(walletCount=scan.payload.eligibleWalletCount,totalVotingPower=scan.payload.totalVotingPower){
 const id=Number(await dao.proposalCount());
 await tx(dao.createProposal(recipient,units(1000000),scan.merkleRoot,{...scan.proposalElectorate,walletCount,totalVotingPower}));
 return id;
}
const id=await create(),second=await create(),denied=await create(),tooFew=await create();
assert.equal(await dao.getQuorumThreshold(id),5n);
await rejects(dao.createProposal(recipient,units(1),scan.merkleRoot,{...scan.proposalElectorate,walletCount:4}));
await rejects(dao.createProposal(recipient,units(1),scan.merkleRoot,{...scan.proposalElectorate,snapshotHash:ethers.id('altered block')}));
const proof=i=>scan.proofs.find(e=>e.wallet===addresses[i]);
await tx(dao.connect(signers[1]).approveProposal(id));
await rejects(dao.connect(signers[5]).castVote(id,true,proof(5).power,proof(5).proof));
await tx(dao.connect(signers[2]).approveProposal(id));
const details=await dao.getProposalDetails(id);
assert.equal(details.votingStart,BigInt(await now()));assert.equal(details.votingEnd-details.votingStart,108000n);
for(const p of [second,denied,tooFew]){await tx(dao.connect(signers[1]).approveProposal(p));await tx(dao.connect(signers[2]).approveProposal(p));}
const fiftyOne=await create(2551,2551);
assert.equal(await dao.getQuorumThreshold(fiftyOne),52n,'ceil(2% of 2551)');
pass('2% eligible-wallet quorum, five-wallet Sepolia floor, third-approval 30-hour opening and canonical-block commitment checks');

async function pauseSystem(nonce){for(let i=0;i<3;i++)await tx(dao.connect(signers[i]).signPauseSystem(ethers.id(nonce)));}
async function unpauseSystem(nonce){for(let i=0;i<3;i++)await tx(dao.connect(signers[i]).signUnpauseSystem(ethers.id(nonce)));}
async function pauseProposal(nonce){for(let i=0;i<3;i++)await tx(dao.connect(signers[i]).signPauseProposal(id,ethers.id(nonce)));}
async function unpauseProposal(nonce){for(let i=0;i<3;i++)await tx(dao.connect(signers[i]).signUnpauseProposal(id,ethers.id(nonce)));}
await pauseSystem('system');const remain=await dao.getVotingTimeRemaining(id);
await advance(10*3600);assert.equal(await dao.getVotingTimeRemaining(id),remain);
await rejects(dao.connect(signers[5]).castVote(id,true,proof(5).power,proof(5).proof));
await unpauseSystem('system');assert.equal(await dao.getVotingTimeRemaining(id),remain);
await pauseProposal('local');const localRemain=await dao.getVotingTimeRemaining(id);
await advance(2*3600);await pauseSystem('overlap');await advance(4*3600);await unpauseSystem('overlap');await advance(2*3600);
assert.equal(await dao.getVotingTimeRemaining(id),localRemain,'overlap must not count twice or consume voting time');
await unpauseProposal('local');assert.equal(await dao.getVotingTimeRemaining(id),localRemain);
pass('system/proposal pauses freeze voting time; overlapping pauses are counted once');

await rejects(dao.connect(signers[5]).castVote(id,true,1000,proof(5).proof));
await rejects(dao.connect(signers[14]).castVote(id,true,1,proof(5).proof));
await tx(oracle.setFailing(true));
await rejects(dao.connect(signers[5]).castVote(id,true,proof(5).power,proof(5).proof));
assert.equal((await dao.getProposalDetails(id)).voterCount,0n);
await provider.send('evm_mine',[]);await provider.send('evm_mine',[]);
await rejects(buildElectorate(provider,{...scanConfig,snapshotBlock:await provider.getBlockNumber()-1}));
await tx(oracle.setFailing(false));
for(let i=5;i<10;i++)await tx(dao.connect(signers[i]).castVote(denied,i<7,proof(i).power,proof(i).proof));
for(let i=5;i<9;i++)await tx(dao.connect(signers[i]).castVote(tooFew,true,proof(i).power,proof(i).proof));
for(const p of [id,second])for(let i=5;i<10;i++)await tx(dao.connect(signers[i]).castVote(p,i<8,proof(i).power,proof(i).proof));
const voted=await dao.getProposalDetails(id);
assert.equal(voted.voterCount,5n);assert.equal(voted.yesVotes,15n);assert.equal(voted.noVotes,10n);
await rejects(dao.connect(signers[5]).castVote(id,true,proof(5).power,proof(5).proof));
await rejects(dao.executeProposal(id));
const effectiveEnd=await dao.getEffectiveVotingEnd(id);
await at(effectiveEnd+108000n-1n);
await rejects(dao.executeProposal.staticCall(id));
await advance(1);assert.equal(await dao.getProposalStatus(id),3n);
assert.equal(await dao.getProposalStatus(denied),4n);await rejects(dao.executeProposal(denied));
assert.equal(await dao.getProposalStatus(tooFew),4n);await rejects(dao.executeProposal(tooFew));
await tx(token.setBlockedRecipient(recipient));
await rejects(dao.executeProposal(id));
assert.equal((await dao.getProposalDetails(id)).executed,false);assert.equal(await dao.totalReleased(),0n);
await tx(token.setBlockedRecipient(ethers.ZeroAddress));
pass('failed majority, insufficient participating wallets, oracle failure and token-transfer failure all fail closed without consuming votes/releases');
const before=await token.balanceOf(recipient);await tx(dao.connect(signers[18]).executeProposal(id));
assert.equal(await token.balanceOf(recipient)-before,units(1000000));
assert.equal(await dao.totalReleased(),units(1000000));
await rejects(dao.executeProposal(second));
const firstRelease=await dao.lastApprovalTimestamp();await at(firstRelease+324000n);
await tx(dao.executeProposal(second));await rejects(dao.executeProposal(second));
pass('51% weighted approval, fixed 5% cap independent of order, minimum participants, 30-hour timelock and 90-hour release spacing');

const oldHash=scan.proposalElectorate.snapshotHash;
await rejects(dao.createProposal(recipient,units(1000001),scan.merkleRoot,scan.proposalElectorate));
await tx(dao.requestWalletReplacement(4,addresses[17]));
await tx(dao.connect(signers[1]).approveWalletReplacement(0));await tx(dao.connect(signers[2]).approveWalletReplacement(0));
assert.equal(await dao.getProposalStatus(fiftyOne),6n);
await rejects(dao.connect(signers[4]).requestWalletReplacement(0,addresses[16]));
await rejects(dao.approveProposal(fiftyOne));
assert.equal((await dao.electorates(id)).snapshotHash,oldHash);
pass('one-million limit, replacement cancels all unfinished proposals and immediately revokes old signer');
console.log(`${groups} Sepolia integration groups passed; optimized runtime ${govArtifact.evm.deployedBytecode.object.length/2} bytes. LOCAL ONLY, no Sepolia transaction sent.`);
await provider.destroy();
