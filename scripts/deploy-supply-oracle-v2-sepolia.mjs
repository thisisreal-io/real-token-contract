// Supply Oracle V2 deployment. Run locally. NEVER commit credentials.
// Required env: SEPOLIA_RPC_URL, DEPLOYER_PRIVATE_KEY, ORACLE_OWNER, REAL_TOKEN,
// TOTAL_ISSUED_EVER (integer base units). Optional: VESTING_FACTORY, DAO_WALLET,
// LP_BURN_ADDRESS, VOTE_EXCLUDED_WALLETS (comma-separated).
// DRY_RUN=1 (default) validates, compiles, and prints the plan without broadcasting.
// Set DRY_RUN=0 to deploy the implementation and atomically initialized ERC1967Proxy.
import fs from 'node:fs';
import path from 'node:path';
import solc from 'solc';
import {ethers} from 'ethers';

const root = path.resolve(import.meta.dirname, '..');
const ZERO = ethers.ZeroAddress;
const required = name => {
  const value = process.env[name];
  if (!value) throw Error('Missing required environment setting: ' + name);
  return value;
};
const address = (name, optional = false) =>
  ethers.getAddress(optional ? (process.env[name] || ZERO) : required(name));
const owner = address('ORACLE_OWNER');
const tokenAddress = address('REAL_TOKEN');
const firstFactory = address('VESTING_FACTORY', true);
const daoWallet = address('DAO_WALLET', true);
const lpBurn = address('LP_BURN_ADDRESS', true);
const exclusions = (process.env.VOTE_EXCLUDED_WALLETS || '').split(',').map(v=>v.trim())
  .filter(Boolean).map(ethers.getAddress);
if (new Set(exclusions).size !== exclusions.length) throw Error('Duplicate vote-excluded address');
const baseline = BigInt(required('TOTAL_ISSUED_EVER'));
const rpc = required('SEPOLIA_RPC_URL');
const provider = new ethers.JsonRpcProvider(rpc);
const network = await provider.getNetwork();
if (network.chainId !== 11155111n) throw Error('Wrong network: expected Sepolia chain ID 11155111');
const token = new ethers.Contract(tokenAddress,[
  'function totalSupply() view returns(uint256)',
  'function decimals() view returns(uint8)'
], provider);
if ((await provider.getCode(tokenAddress)) === '0x') throw Error('REAL_TOKEN has no contract code');
const [liveSupply, decimals] = await Promise.all([token.totalSupply(), token.decimals()]);
if (decimals !== 18n) throw Error('REAL_TOKEN must use 18 decimals');
if (baseline < liveSupply || baseline > ethers.parseEther('100000000'))
  throw Error('Invalid TOTAL_ISSUED_EVER baseline');
if (firstFactory !== ZERO) {
  if ((await provider.getCode(firstFactory)) === '0x') throw Error('VESTING_FACTORY has no code');
  const factory = new ethers.Contract(firstFactory,[
    'function realToken() view returns(address)',
    'function totalLocked() view returns(uint256)',
    'function getTotalDeployedContracts() view returns(uint256)'
  ],provider);
  if ((await factory.realToken()).toLowerCase() !== tokenAddress.toLowerCase())
    throw Error('Factory token does not match REAL_TOKEN');
  await factory.totalLocked();
  await factory.getTotalDeployedContracts();
}
function importFile(name) {
  const normalized = name
    .replace('@openzeppelin/contracts-upgradeable@5.1.0/','@openzeppelin/contracts-upgradeable/')
    .replace('@openzeppelin/contracts@5.1.0/','@openzeppelin/contracts/');
  const full = path.resolve(root,'node_modules',normalized);
  if (!full.startsWith(path.resolve(root,'node_modules') + path.sep)) throw Error('Invalid import path');
  return fs.readFileSync(full,'utf8');
}
const source = fs.readFileSync(path.join(root,'SupplyOracleV2.sol'),'utf8');
const proxyName='@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';
const input = {language:'Solidity',sources:{
  'SupplyOracleV2.sol':{content:source},
  [proxyName]:{content:importFile(proxyName)}
},settings:{optimizer:{enabled:true,runs:200},evmVersion:'cancun',
  outputSelection:{'*':{'*':['abi','evm.bytecode.object']}}}};
const compiled=JSON.parse(solc.compile(JSON.stringify(input),{
  import:name=>{try{return {contents:importFile(name)};}catch(e){return {error:e.message};}}
}));
const errors=(compiled.errors||[]).filter(e=>e.severity==='error');
if (errors.length) throw Error(errors.map(e=>e.formattedMessage).join('\n'));
const oracle=compiled.contracts['SupplyOracleV2.sol'].SupplyOracleV2;
const proxy=compiled.contracts[proxyName].ERC1967Proxy;
const init=new ethers.Interface(oracle.abi).encodeFunctionData('initialize',[
  owner,tokenAddress,baseline,firstFactory,daoWallet,lpBurn,exclusions]);
console.log(JSON.stringify({network:'Sepolia',chainId:11155111,owner,tokenAddress,
  liveSupply:liveSupply.toString(),issuedSupplyBaseline:baseline.toString(),
  firstFactory,daoWallet,lpBurn,voteExcludedWallets:exclusions,
  compiler:'0.8.28',evmVersion:'cancun',openzeppelin:'5.1.0',
  dryRun:process.env.DRY_RUN!=='0'},null,2));
if (process.env.DRY_RUN !== '0') {
  console.log('DRY RUN ONLY. To broadcast, use DRY_RUN=0 with a locally stored deployer key.');
  process.exit(0);
}
const signer = new ethers.Wallet(required('DEPLOYER_PRIVATE_KEY'),provider);
console.log('Broadcasting with deployer:',await signer.getAddress());
const impl = await new ethers.ContractFactory(oracle.abi,oracle.evm.bytecode.object,signer).deploy();
await impl.waitForDeployment();
console.log('Implementation:',await impl.getAddress(),'tx:',impl.deploymentTransaction().hash);
const proxyContract = await new ethers.ContractFactory(proxy.abi,proxy.evm.bytecode.object,signer)
  .deploy(await impl.getAddress(),init);
await proxyContract.waitForDeployment();
const proxyAddress = await proxyContract.getAddress();
const live = new ethers.Contract(proxyAddress,oracle.abi,provider);
if ((await live.owner()).toLowerCase() !== owner.toLowerCase()) throw Error('Proxy owner mismatch');
if ((await live.realToken()).toLowerCase() !== tokenAddress.toLowerCase()) throw Error('Proxy token mismatch');
if (await live.issuedSupplyBaseline() !== baseline) throw Error('Proxy supply baseline mismatch');
console.log('DEPLOYED proxy:',proxyAddress,'tx:',proxyContract.deploymentTransaction().hash);
console.log('Circulating:',(await live.getCirculatingSupply()).toString());
