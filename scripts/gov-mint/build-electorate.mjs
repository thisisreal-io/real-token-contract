import fs from 'node:fs';
import {pathToFileURL} from 'node:url';
import {ethers} from 'ethers';

export const UNIT=1000n*10n**18n;
const zero=ethers.ZeroAddress.toLowerCase();
const abi=new ethers.AbiCoder();
export function voteLeaf(context,wallet,power) {
  return ethers.keccak256(abi.encode(['uint256','address','address','uint256','bytes32','address','uint256'],
    [context.chainId,context.dao,context.token,context.snapshotBlock,context.snapshotHash,wallet,power]));
}
export function treeFor(context,entries) {
  if(!entries.length)throw Error('No eligible wallets');
  const levels=[entries.map(e=>voteLeaf(context,e.wallet,e.power))];
  while(levels.at(-1).length>1){const a=levels.at(-1),next=[];
    for(let i=0;i<a.length;i+=2)next.push(i+1===a.length?a[i]:ethers.keccak256(ethers.concat([a[i],a[i+1]].sort())));
    levels.push(next);
  }
  const proofs=entries.map((_,i)=>{const result=[];for(let l=0;l<levels.length-1;l++){
    const j=i^1;if(j<levels[l].length)result.push(levels[l][j]);i=Math.floor(i/2);
  }return result;});
  return {root:levels.at(-1)[0],proofs};
}
// Replay EVERY Transfer in block/transaction/log order, not periodic samples.
// Inputs are balances at the block immediately at/before the lookback boundary.
export function minimumBalances(startBalances,logs) {
  const balances=new Map([...startBalances].map(([a,b])=>[a.toLowerCase(),BigInt(b)]));
  const minimum=new Map(balances);let previous=null;
  for(const log of logs){
    const position=[Number(log.blockNumber),Number(log.transactionIndex),Number(log.index)];
    if(previous){let cmp=0;for(let i=0;i<3;i++){if(position[i]!==previous[i]){cmp=position[i]-previous[i];break;}}
      if(cmp<=0)throw Error('Duplicate or unordered Transfer log');}
    previous=position;
    const from=log.from.toLowerCase(),to=log.to.toLowerCase(),value=BigInt(log.value);
    if(value<0n)throw Error('Negative transfer');
    if(from===to)continue;
    for(const [wallet,delta] of [[from,-value],[to,value]]){
      if(wallet===zero)continue;
      if(!balances.has(wallet))throw Error('Candidate set incomplete');
      const next=balances.get(wallet)+delta;if(next<0n)throw Error('Transfer history inconsistent with opening balance');
      balances.set(wallet,next);if(next<minimum.get(wallet))minimum.set(wallet,next);
    }
  }
  return {balances,minimum};
}

export async function buildElectorate(provider,config) {
  const network=await provider.getNetwork();
  if(![11155111n,31337n].includes(network.chainId))throw Error('Sepolia/local test builder only');
  const daoAddress=ethers.getAddress(config.dao),tokenAddress=ethers.getAddress(config.token);
  const dao=new ethers.Contract(daoAddress,[
    'function realToken() view returns(address)','function supplyOracle() view returns(address)',
    'function authorizedWallets(uint256) view returns(address)','function corporateWallet(address) view returns(bool)',
    'function timingConfiguration() pure returns(uint256,uint256,uint256,uint256,uint256)'
  ],provider);
  if((await dao.realToken())!==tokenAddress)throw Error('Wrong token for DAO');
  const timing=await dao.timingConfiguration(),holding=Number(timing[0]);
  if(holding!==30*3600)throw Error('Expected Sepolia 30-hour holding configuration');
  const token=new ethers.Contract(tokenAddress,[
    'function balanceOf(address) view returns(uint256)','function totalSupply() view returns(uint256)',
    'function decimals() view returns(uint8)','event Transfer(address indexed from,address indexed to,uint256 value)'
  ],provider);
  if(await token.decimals()!==18n)throw Error('18-decimal REAL required');
  const tip=await provider.getBlockNumber();
  const snapshotBlock=config.snapshotBlock??tip-2;
  if(!Number.isSafeInteger(snapshotBlock))throw Error('snapshotBlock must be an integer');
  if(snapshotBlock<0||snapshotBlock>=tip||tip-snapshotBlock>128)throw Error('Choose a recent completed snapshot block');
  const snapshot=await provider.getBlock(snapshotBlock);if(!snapshot)throw Error('Missing snapshot block');
  const startTimestamp=snapshot.timestamp-holding;
  if(config.tokenDeploymentBlock===null||config.tokenDeploymentBlock===undefined)throw Error('tokenDeploymentBlock required');
  const deploymentBlock=Number(config.tokenDeploymentBlock);
  if(!Number.isSafeInteger(deploymentBlock)||deploymentBlock<0)throw Error('tokenDeploymentBlock required');
  const deployment=await provider.getBlock(deploymentBlock);
  if(!deployment||deployment.timestamp>startTimestamp)throw Error('Token has not existed for the full holding period');
  // Last block at/before the lookback boundary: balance applies until next block.
  let low=deploymentBlock,high=snapshotBlock;
  while(low<high){const mid=Math.ceil((low+high)/2),b=await provider.getBlock(mid);
    if(!b)throw Error('Missing historical block');
    if(b.timestamp<=startTimestamp)low=mid;else high=mid-1;
  }
  const anchorBlock=low,anchor=await provider.getBlock(anchorBlock);
  const iface=token.interface,topic=iface.getEvent('Transfer').topicHash;
  const step=Number(config.logBlockRange??1000);
  if(!Number.isSafeInteger(step)||step<1||step>10000)throw Error('Invalid log range');
  const candidates=new Set(),history=[];const observed=new Set();
  for(let fromBlock=deploymentBlock;fromBlock<=snapshotBlock;fromBlock+=step){
    const toBlock=Math.min(snapshotBlock,fromBlock+step-1);
    const logs=await provider.getLogs({address:tokenAddress,topics:[topic],fromBlock,toBlock});
    for(const l of logs){
      if(l.removed||l.blockNumber<fromBlock||l.blockNumber>toBlock||l.address.toLowerCase()!==tokenAddress.toLowerCase())throw Error('Invalid/removed log');
      const key=`${l.blockHash}:${l.index}`;if(observed.has(key))throw Error('Duplicate RPC log');observed.add(key);
      const decoded=iface.parseLog(l);for(const a of [decoded.args.from,decoded.args.to])if(a!==ethers.ZeroAddress)candidates.add(a.toLowerCase());
      if(l.blockNumber>anchorBlock)history.push({...l,from:decoded.args.from,to:decoded.args.to,value:decoded.args.value});
    }
  }
  history.sort((a,b)=>a.blockNumber-b.blockNumber||a.transactionIndex-b.transactionIndex||a.index-b.index);
  const opening=new Map();for(const wallet of [...candidates].sort())opening.set(wallet,await token.balanceOf(wallet,{blockTag:anchorBlock}));
  const {minimum,balances}=minimumBalances(opening,history);
  const oracleAddress=await dao.supplyOracle();
  const oracle=new ethers.Contract(oracleAddress,['function isVotingExcluded(address) view returns(bool)','function getCirculatingSupply() view returns(uint256)'],provider);
  const exclusions=new Set((config.excludedWallets||[]).map(x=>ethers.getAddress(x).toLowerCase()));
  exclusions.add(daoAddress.toLowerCase());exclusions.add(tokenAddress.toLowerCase());exclusions.add(oracleAddress.toLowerCase());
  for(let i=0;i<5;i++)exclusions.add((await dao.authorizedWallets(i,{blockTag:snapshotBlock})).toLowerCase());
  const entries=[],excluded=[];let totalVotingPower=0n,eligibleTokenBalance=0n;
  for(const wallet of [...candidates].sort()){
    const final=await token.balanceOf(wallet,{blockTag:snapshotBlock});
    if(final!==balances.get(wallet))throw Error(`Incomplete history or unsupported token behavior for ${wallet}`);
    const min=minimum.get(wallet),power=min/UNIT;
    let reason=power===0n?'below-1000-held-throughout':null;
    if(exclusions.has(wallet)||await dao.corporateWallet(wallet,{blockTag:snapshotBlock})||await oracle.isVotingExcluded(wallet,{blockTag:snapshotBlock}))reason='excluded-system-or-corporate';
    if(await provider.getCode(wallet,snapshotBlock)!=='0x')reason='contract-wallet-excluded-by-current-policy';
    if(reason){excluded.push({wallet,reason,minimumBalance:min.toString()});continue;}
    entries.push({wallet:ethers.getAddress(wallet),minimumBalance:min.toString(),power:power.toString()});
    totalVotingPower+=power;eligibleTokenBalance+=min;
  }
  if(entries.length<Number(timing[4]))throw Error('Not enough eligible wallets for Sepolia minimum');
  const tokenTotal=await token.totalSupply({blockTag:snapshotBlock});
  if(totalVotingPower>tokenTotal/UNIT)throw Error('Electorate exceeds token supply');
  if((await provider.getBlock(snapshotBlock)).hash!==snapshot.hash||(await provider.getBlock(anchorBlock)).hash!==anchor.hash)throw Error('Reorg during snapshot construction; discard manifest');
  const context={chainId:network.chainId.toString(),dao:daoAddress,token:tokenAddress,snapshotBlock,snapshotHash:snapshot.hash};
  const payload={schema:'GOV-MINT-SEPOLIA-ATTESTED-1',...context,holdingSeconds:holding,startTimestamp,anchorBlock,anchorHash:anchor.hash,
    oracle:oracleAddress,circulatingSupply:(await oracle.getCirculatingSupply({blockTag:snapshotBlock})).toString(),
    eligibleWalletCount:entries.length,totalVotingPower:totalVotingPower.toString(),eligibleTokenBalance:eligibleTokenBalance.toString(),
    excludedWallets:[...exclusions].sort(),entries,excluded,
    trust:'RPC transfer-history completeness is assumed; three signer attestations are required. This is NOT an on-chain history proof.'};
  const manifestHash=ethers.keccak256(ethers.toUtf8Bytes(JSON.stringify(payload)));
  const tree=treeFor(context,entries);
  return {payload,manifestHash,merkleRoot:tree.root,proofs:entries.map((e,i)=>({...e,proof:tree.proofs[i]})),
    proposalElectorate:{walletCount:entries.length,totalVotingPower:totalVotingPower.toString(),circulatingSupply:payload.circulatingSupply,snapshotBlock,snapshotHash:snapshot.hash,manifestHash}};
}

if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){
  try{
    const config=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
    if(!process.env.SEPOLIA_RPC_URL)throw Error('Set SEPOLIA_RPC_URL; no private key is needed');
    const provider=new ethers.JsonRpcProvider(process.env.SEPOLIA_RPC_URL,undefined,{cacheTimeout:-1});
    try{console.log(JSON.stringify(await buildElectorate(provider,config),null,2));}finally{provider.destroy();}
  }catch(e){console.error(e.shortMessage||e.message);process.exitCode=1;}
}
