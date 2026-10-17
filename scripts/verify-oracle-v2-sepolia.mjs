import { ethers } from 'ethers';
const tokenAddress='0xe6654E7dbD7CAF7b5a2eD068a3c945fD208000Fa';
const factoryAddress='0xd964e11dA64dB950EC7e97ED5363e78F2BdC345a';
const owner='0xbF44702EdC6A288691212C1503B07a9F860Fdbef';
const endpoints=[process.env.SEPOLIA_RPC_URL,'https://ethereum-sepolia-rpc.publicnode.com','https://sepolia.drpc.org','https://rpc.sepolia.org'].filter(Boolean);
const report=[];
for (const endpoint of endpoints) {
  try {
    const rpc = new ethers.JsonRpcProvider(endpoint,11155111,{staticNetwork:true});
    const code=await Promise.all([rpc.getCode(tokenAddress),rpc.getCode(factoryAddress)]);
    if(code.some(c=>c==='0x'))throw new Error('Missing contract bytecode');
    const token = new ethers.Contract(tokenAddress,[
      'function decimals() view returns(uint8)',
      'function totalSupply() view returns(uint256)',
      'function balanceOf(address) view returns(uint256)',
      'function symbol() view returns(string)'
    ],rpc);
    const factory = new ethers.Contract(factoryAddress,[
      'function realToken() view returns(address)',
      'function totalLocked() view returns(uint256)',
      'function getTotalDeployedContracts() view returns(uint256)'
    ],rpc);
    const [decimals,supply,balance,symbol,factoryToken,locked,count]=await Promise.all([
      token.decimals(),token.totalSupply(),token.balanceOf(owner),token.symbol(),
      factory.realToken(),factory.totalLocked(),factory.getTotalDeployedContracts()
    ]);
    const ok=factoryToken.toLowerCase()===tokenAddress.toLowerCase() && decimals===18n;
    console.log(JSON.stringify({network:'Sepolia',chainId:11155111,
       tokenAddress,factoryAddress,owner,symbol,decimals:Number(decimals),
       totalSupplyRaw:supply.toString(),ownerBalanceRaw:balance.toString(),
       factoryToken,vestingLockedRaw:locked.toString(),vestingContractCount:count.toString(),
       factoryTokenMatch:factoryToken.toLowerCase()===tokenAddress.toLowerCase(),valid:ok},null,2));
    if(!ok)process.exitCode=1;
    process.exit();
  } catch(e) {
    report.push({rpcHost:new URL(endpoint).hostname,error:String(e).slice(0,250)});
  }
}
console.error('No Sepolia provider returned verified results:',JSON.stringify(report));
process.exit(1);
