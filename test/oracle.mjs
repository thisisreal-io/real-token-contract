import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import solc from 'solc';
import {ethers} from 'ethers';

const root = path.resolve(import.meta.dirname, '..');
const source = fs.readFileSync(path.join(root, 'CirculatingSupplyOracle.sol'), 'utf8');
const mocks = `// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {ERC20} from "@openzeppelin/contracts@5.1.0/token/ERC20/ERC20.sol";
import {CirculatingSupplyOracle} from "./CirculatingSupplyOracle.sol";
contract TestToken is ERC20 {
    constructor() ERC20("REAL", "REAL") { _mint(msg.sender, 100_000_000 ether); }
    function burn(uint256 amount) external { _burn(msg.sender, amount); }
}
contract TestFactory {
    address public realToken;
    uint256 public totalLocked;
    uint256 public getTotalDeployedContracts;
    constructor(address token) { realToken = token; }
    function setValues(uint256 locked, uint256 count) external {
        totalLocked = locked; getTotalDeployedContracts = count;
    }
}
contract TestPair is ERC20 {
    address public token0;
    address public token1;
    constructor(address a, address b) ERC20("LP", "LP") { token0 = a; token1 = b; }
    function mint(address recipient, uint256 amount) external { _mint(recipient, amount); }
}
contract OracleV2 is CirculatingSupplyOracle {
    function version() external pure returns (uint256) { return 2; }
}
`;
const input = {language:'Solidity', sources:{
    'CirculatingSupplyOracle.sol':{content:source},
    'Mocks.sol':{content:mocks},
    '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol':{content:readImport('@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol')}
},settings:{optimizer:{enabled:true,runs:200},evmVersion:'cancun',outputSelection:{'*':{'*':['abi','evm.bytecode.object']}}}};

function readImport(name) {
    const normalized = name.replace('@openzeppelin/contracts-upgradeable@5.1.0/', '@openzeppelin/contracts-upgradeable/')
        .replace('@openzeppelin/contracts@5.1.0/', '@openzeppelin/contracts/');
    const standard = path.join(root,'node_modules',normalized);
    if (fs.existsSync(standard)) return fs.readFileSync(standard,'utf8');
    // Local audit harness supports isolated offline reproduction with the same pinned OZ sources.
    const vendor = process.env.OZ_VENDOR_DIR && path.join(process.env.OZ_VENDOR_DIR,normalized);
    if (vendor && fs.existsSync(vendor)) return fs.readFileSync(vendor,'utf8');
    throw Error(`Missing import ${name}; run npm install`);
}
const output=JSON.parse(solc.compile(JSON.stringify(input),{import:(name)=>{
    try { return {contents:readImport(name)}; } catch(e) { return {error:e.message}; }
}}));
assert.deepEqual((output.errors||[]).filter(x=>x.severity==='error').map(x=>x.formattedMessage),[]);
const artifact=(file,name)=>output.contracts[file][name];
const provider=new ethers.JsonRpcProvider(process.env.REAL_ORACLE_TEST_RPC || 'http://127.0.0.1:18547');
const [admin,attacker,dao,safe,nextOwner,burnWallet,quoteEth,quoteUsd]=await Promise.all(
    Array.from({length:8},(_,i)=>provider.getSigner(i)));
const addr=async signer=>signer.getAddress();
const token=await deploy('Mocks.sol','TestToken',admin);
const tokenAddress=await token.getAddress();
const factory=await deploy('Mocks.sol','TestFactory',admin,[tokenAddress]);
const impl=await deploy('CirculatingSupplyOracle.sol','CirculatingSupplyOracle',admin);
const abi=artifact('CirculatingSupplyOracle.sol','CirculatingSupplyOracle').abi;
const init=new ethers.Interface(abi).encodeFunctionData('initialize',[
    await addr(nextOwner),tokenAddress,ethers.parseEther('100000000'),await factory.getAddress(),
    await addr(dao),await addr(burnWallet),[await addr(safe),await addr(safe),ethers.ZeroAddress]
]);
const proxy=await deploy('@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol','ERC1967Proxy',admin,[await impl.getAddress(),init]);
const oracle=new ethers.Contract(await proxy.getAddress(),abi,nextOwner);
assert.equal(await oracle.owner(),await addr(nextOwner),'proxy initialized atomically with intended owner');
assert.equal(await oracle.deployer(),await addr(nextOwner));
assert.equal(await oracle.getVoteExcludedWalletCount(),1n);
assert.equal(await oracle.getFactoryCount(),1n);
await reverts(impl.initialize(await addr(attacker),tokenAddress,ethers.parseEther('100000000'),ethers.ZeroAddress,ethers.ZeroAddress,ethers.ZeroAddress,[]));
await reverts(oracle.connect(attacker).initialize(await addr(attacker),tokenAddress,ethers.parseEther('100000000'),ethers.ZeroAddress,ethers.ZeroAddress,ethers.ZeroAddress,[]));
await reverts(oracle.connect(attacker).setDaoWallet(await addr(attacker)));
await reverts(oracle.connect(attacker).upgradeToAndCall(await impl.getAddress(),'0x'));
await reverts(oracle.renounceOwnership());

// Safe holdings count as circulating; vesting and DAO holdings do not.
await tx(token.transfer(await addr(dao),ethers.parseEther('79000000')));
await tx(factory.setValues(ethers.parseEther('19000000'),300));
assert.equal(await oracle.getCirculatingSupply(),ethers.parseEther('2000000'));
await tx(token.transfer(await addr(safe),ethers.parseEther('1000000')));
assert.equal(await oracle.getCirculatingSupply(),ethers.parseEther('2000000'));
assert.equal(await oracle.isVotingExcluded(await addr(safe)),true);
assert.equal(await oracle.isVotingExcluded(await addr(dao)),true);
await tx(oracle.removeVoteExcludedWallet(await addr(safe)));
assert.equal(await oracle.isVotingExcluded(await addr(safe)),false);
assert.equal(await oracle.getCirculatingSupply(),ethers.parseEther('2000000'));
await tx(oracle.addVoteExcludedWallet(await addr(safe)));
await tx(factory.setValues(ethers.parseEther('18000000'),300));
assert.equal(await oracle.getCirculatingSupply(),ethers.parseEther('3000000'));
await tx(token.burn(ethers.parseEther('1000000')));
assert.equal(await oracle.getBurnedSupply(),ethers.parseEther('1000000'));
assert.equal(await oracle.getCirculatingSupply(),ethers.parseEther('2000000'));
await tx(token.transfer(await addr(burnWallet),ethers.parseEther('1')));
assert.equal(await oracle.getBurnedSupply(),ethers.parseEther('1000000'),'transfer to dead address is not ERC20 burn');
assert.equal(await oracle.getMaxSupply(),ethers.parseEther('100000000'));
assert.equal(await oracle.getVestingContractCount(),300n);

const second=await deploy('Mocks.sol','TestFactory',admin,[tokenAddress]);
await tx(second.setValues(ethers.parseEther('1000000'),100));
await tx(oracle.addVestingFactory(await second.getAddress()));
assert.equal(await oracle.getVestingLockedBalance(),ethers.parseEther('19000000'));
assert.equal(await oracle.getVestingContractCount(),400n);
assert.deepEqual([...await oracle.getVestingFactories()],[await factory.getAddress(),await second.getAddress()]);
assert.equal(await oracle.getCirculatingSupply(),ethers.parseEther('1000000'));
await reverts(oracle.addVestingFactory(await second.getAddress()));
await reverts(oracle.setVestingFactory(await second.getAddress()));
await reverts(oracle.addVestingFactory(await addr(attacker)));
const bad=await deploy('Mocks.sol','TestFactory',admin,[await addr(attacker)]);
await reverts(oracle.addVestingFactory(await bad.getAddress()));
await tx(second.setValues(ethers.parseEther('100000000'),100));
await reverts(oracle.getCirculatingSupply());
await tx(second.setValues(ethers.parseEther('1000000'),100));

const pairEth=await deploy('Mocks.sol','TestPair',admin,[tokenAddress,await addr(quoteEth)]);
const pairUsd=await deploy('Mocks.sol','TestPair',admin,[await addr(quoteUsd),tokenAddress]);
await reverts(oracle.setEthLpPair(await pairEth.getAddress(),await addr(quoteUsd)));
await tx(oracle.setEthLpPair(await pairEth.getAddress(),await addr(quoteEth)));
await reverts(oracle.setUsdcLpPair(await pairEth.getAddress(),await addr(quoteEth)));
await tx(oracle.setUsdcLpPair(await pairUsd.getAddress(),await addr(quoteUsd)));
await tx(pairEth.mint(await addr(burnWallet),ethers.parseEther('500')));
await tx(pairUsd.mint(await addr(burnWallet),ethers.parseEther('200')));
assert.equal(await oracle.getEthLpBurned(),ethers.parseEther('500'));
assert.equal(await oracle.getUsdcLpBurned(),ethers.parseEther('200'));
assert.equal(await oracle.getEthLpTotalSupply(),ethers.parseEther('500'));
assert.equal(await oracle.getCirculatingSupply(),ethers.parseEther('1000000'),'LP lock does not alter REAL circulation');
await tx(oracle.setDaoWallet(ethers.ZeroAddress));
assert.equal(await oracle.getCirculatingSupply(),ethers.parseEther('80000000'));
assert.equal(await oracle.isVotingExcluded(await addr(dao)),false);
await tx(oracle.setDaoWallet(await addr(dao)));

// Ownership uses acceptance; new owner inherits both configuration and upgrade authority.
await tx(oracle.transferOwnership(await addr(admin)));
assert.equal(await oracle.owner(),await addr(nextOwner));
await reverts(oracle.connect(attacker).acceptOwnership());
await tx(oracle.connect(admin).acceptOwnership());
assert.equal(await oracle.deployer(),await addr(admin));
await reverts(oracle.setDaoWallet(ethers.ZeroAddress));
await tx(oracle.connect(admin).setDaoWallet(await addr(dao)));
const v2impl=await deploy('Mocks.sol','OracleV2',admin);
await reverts(oracle.upgradeToAndCall(await v2impl.getAddress(),'0x'));
await tx(oracle.connect(admin).upgradeToAndCall(await v2impl.getAddress(),'0x'));
const upgraded=new ethers.Contract(await proxy.getAddress(),artifact('Mocks.sol','OracleV2').abi,admin);
assert.equal(await upgraded.version(),2n);
assert.equal(await upgraded.getCirculatingSupply(),ethers.parseEther('1000000'));
assert.equal(await upgraded.owner(),await addr(admin));

console.log('PASS: Cancun compile and proxy tests: atomic initializer, roles and upgrade, burn/supply invariant, Safe/DAO accounting, multi-factory aggregation, LP reporting, voting exclusion');

async function deploy(file,name,signer,args=[]) {
    const a=artifact(file,name);
    const c=await new ethers.ContractFactory(a.abi,a.evm.bytecode.object,signer).deploy(...args);
    await c.waitForDeployment();
    return c;
}
async function tx(p) { await (await p).wait(); }
async function reverts(p) { await assert.rejects(async()=>{await tx(p);}); }
