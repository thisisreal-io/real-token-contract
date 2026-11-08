import fs from 'node:fs';
import {pathToFileURL} from 'node:url';
import {ethers} from 'ethers';
import {compileGov,root} from './compile.mjs';
import path from 'node:path';

export async function prepareSepolia(provider,config,{local=false}={}) {
  const chainId=(await provider.getNetwork()).chainId;
  if(chainId!==(local?31337n:11155111n)||BigInt(config.chainId)!==chainId)throw Error('Wrong chain: Sepolia required (local mode is explicit)');
  const from=ethers.getAddress(config.deployer),token=ethers.getAddress(config.token),oracle=ethers.getAddress(config.oracle);
  const signers=config.authorizedWallets.map(ethers.getAddress);
  if(signers.length!==5||new Set(signers).size!==5||signers.some(x=>x===ethers.ZeroAddress))throw Error('Exactly five distinct nonzero authorized wallets required');
  for(const address of [token,oracle])if(await provider.getCode(address)==='0x')throw Error('Token/oracle contract missing');
  const t=new ethers.Contract(token,['function decimals() view returns(uint8)','function totalSupply() view returns(uint256)'],provider);
  if(await t.decimals()!==18n||await t.totalSupply()<=0n)throw Error('Invalid 18-decimal test REAL');
  const o=new ethers.Contract(oracle,['function getCirculatingSupply() view returns(uint256)','function isVotingExcluded(address) view returns(bool)'],provider);
  const circulating=await o.getCirculatingSupply();if(circulating>await t.totalSupply())throw Error('Oracle accounting exceeds total supply');
  await o.isVotingExcluded(signers[0]);
  const proxyFile='@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';
  const contracts=compileGov({[proxyFile]:{content:fs.readFileSync(path.join(root,'node_modules',proxyFile),'utf8')}});
  const gov=contracts['GOV MINT Sepolia v2.sol'].GOVMINTSepoliaV2,proxy=contracts[proxyFile].ERC1967Proxy;
  const nonce=await provider.getTransactionCount(from,'pending');
  const implementation=ethers.getCreateAddress({from,nonce}),dao=ethers.getCreateAddress({from,nonce:nonce+1});
  if(signers.includes(dao))throw Error('DAO cannot be an authorized signer');
  const init=new ethers.Interface(gov.abi).encodeFunctionData('initialize',[token,oracle,signers]);
  const implementationData='0x'+gov.evm.bytecode.object;
  const proxyData=await new ethers.ContractFactory(proxy.abi,proxy.evm.bytecode.object).getDeployTransaction(implementation,init);
  return {
    contractName:'GOVMINTSepoliaV2',compiler:'0.8.28',optimizerRuns:200,evmVersion:'cancun',abi:gov.abi,proxyConstructorArguments:[implementation,init],
    status:'UNSIGNED_SEPOLIA_TEST_PLAN',chainId:chainId.toString(),from,expectedNonce:nonce,implementation,dao,
    settings:{holdingHours:30,votingHours:30,timelockHours:30,cooldownHours:90,minimumVoters:5,walletQuorumBps:200,approvalBps:5100,walletCapBps:500},
    implementationRuntimeBytes:gov.evm.deployedBytecode.object.length/2,
    transactions:[{chainId:chainId.toString(),from,nonce,value:'0',data:implementationData},
      {chainId:chainId.toString(),from,nonce:nonce+1,value:'0',data:proxyData.data}],
    sourceHashes:{implementationCreationHash:ethers.keccak256(implementationData),initializerHash:ethers.keccak256(init)},
    warnings:[
      'No transaction was signed or sent. Recheck pending nonce immediately before using either transaction.',
      'Initialize the fixed proxy atomically; do not deploy an empty/uninitialized proxy.',
      'Only mock/test assets. Three signers attest RPC-derived eligibility; complete history is not independently verified on-chain.',
      'Historical snapshot precedes proposal creation and is frozen for the vote. Approval must finish within native blockhash availability.',
      'Prepare/fund five independent public-voter wallets in addition to the five corporate signer wallets; corporate signers cannot vote.',
      'With a 5% whole-vote cap, seed enough eligible voting power to avoid rounding every wallet to zero.'
    ]
  };
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){
  try{
    if(!process.env.SEPOLIA_RPC_URL)throw Error('Set SEPOLIA_RPC_URL; private keys are not used');
    const config=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
    const provider=new ethers.JsonRpcProvider(process.env.SEPOLIA_RPC_URL,undefined,{cacheTimeout:-1});
    try{console.log(JSON.stringify(await prepareSepolia(provider,config),null,2));}finally{provider.destroy();}
  }catch(e){console.error(e.shortMessage||e.message);process.exitCode=1;}
}
