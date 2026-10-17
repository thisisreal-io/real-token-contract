import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import solc from 'solc';
import {ethers} from 'ethers';

const root = path.resolve(import.meta.dirname, '..');
const source = fs.readFileSync(path.join(root, 'REALSupplyOracle.sol'), 'utf8');
const mocks = `// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {ERC20} from "@openzeppelin/contracts@5.1.0/token/ERC20/ERC20.sol";
import {REALSupplyOracle} from "./REALSupplyOracle.sol";
contract TestToken is ERC20 {
    constructor() ERC20("REAL", "REAL") { _mint(msg.sender, 100_000_000 ether); }
    function burn(uint256 amount) external { _burn(msg.sender, amount); }
}
contract TestFactory {
    address public realToken;
    mapping(address => bool) public isDeployedVesting;
    function setDeployedVesting(address wallet) external { isDeployedVesting[wallet] = true; }
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
contract TestRewards {
    address public realToken;
    uint256 public getUndistributedRewards;
    constructor(address t) { realToken=t; }
    function setReserve(uint256 amount) external {getUndistributedRewards=amount;}
}
contract TestStaking {
    address public realToken;
    constructor(address t) {realToken=t;}
    function getStakingMetrics() external pure returns(uint256,uint256,uint256) {return (123 ether,7,3);}
}
contract OracleV2 is REALSupplyOracle {
    function version() external pure returns (uint256) { return 2; }
}
`;
const input = {language:'Solidity', sources:{
    'REALSupplyOracle.sol':{content:source},
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
assert.equal((await provider.getNetwork()).chainId,31337n,'tests must run on the isolated local chain');
const [admin,attacker,dao,safe,nextOwner,burnWallet,quoteEth,quoteUsd]=await Promise.all(
    Array.from({length:8},(_,i)=>provider.getSigner(i)));
const addr=async signer=>signer.getAddress();
const token=await deploy('Mocks.sol','TestToken',admin);
const tokenAddress=await token.getAddress();
const factory=await deploy('Mocks.sol','TestFactory',admin,[tokenAddress]);
const impl=await deploy('REALSupplyOracle.sol','REALSupplyOracle',admin);
const abi=artifact('REALSupplyOracle.sol','REALSupplyOracle').abi;
const init=new ethers.Interface(abi).encodeFunctionData('initialize',[
    await addr(nextOwner),tokenAddress,ethers.parseEther('100000000'),await factory.getAddress(),
    await addr(dao),await addr(burnWallet),[await addr(safe),await addr(safe),ethers.ZeroAddress],ethers.ZeroAddress,ethers.ZeroAddress
]);
const proxy=await deploy('@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol','ERC1967Proxy',admin,[await impl.getAddress(),init]);
const oracle=new ethers.Contract(await proxy.getAddress(),abi,nextOwner);
assert.equal(await oracle.owner(),await addr(nextOwner),'proxy initialized atomically with intended owner');
assert.equal(await oracle.deployer(),await addr(nextOwner));
assert.equal(await oracle.getVoteExcludedWalletCount(),1n);
assert.equal(await oracle.getFactoryCount(),1n);
await reverts(impl.initialize(await addr(attacker),tokenAddress,ethers.parseEther('100000000'),ethers.ZeroAddress,ethers.ZeroAddress,ethers.ZeroAddress,[],ethers.ZeroAddress,ethers.ZeroAddress));
await reverts(oracle.connect(attacker).initialize(await addr(attacker),tokenAddress,ethers.parseEther('100000000'),ethers.ZeroAddress,ethers.ZeroAddress,ethers.ZeroAddress,[],ethers.ZeroAddress,ethers.ZeroAddress));
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

// Reserves are excluded; user staking is informational and remains circulating.
const initialCirculating=await upgraded.getCirculatingSupply();
await tx(upgraded.setRewardsReserve(await addr(safe),ethers.ZeroAddress));
assert.equal(await upgraded.getRewardsReserveBalance(),ethers.parseEther('1000000'));
assert.equal(await upgraded.getCirculatingSupply(),initialCirculating-ethers.parseEther('1000000'));
await reverts(upgraded.setDaoWallet(await addr(safe)));
await reverts(upgraded.setRewardsReserve(await addr(dao),ethers.ZeroAddress));
await reverts(upgraded.setRewardsReserve(await factory.getAddress(),ethers.ZeroAddress));
await reverts(upgraded.connect(attacker).setRewardsReserve(ethers.ZeroAddress,ethers.ZeroAddress));
await tx(token.connect(safe).transfer(await addr(attacker),ethers.parseEther('100')));
assert.equal(await upgraded.getRewardsReserveBalance(),ethers.parseEther('999900'));
assert.equal(await upgraded.getCirculatingSupply(),initialCirculating-ethers.parseEther('999900'));
const rewardSource=await deploy('Mocks.sol','TestRewards',admin,[tokenAddress]);
await tx(rewardSource.setReserve(ethers.parseEther('100')));
await reverts(upgraded.setRewardsReserve(await addr(safe),await rewardSource.getAddress()));
await tx(upgraded.setRewardsReserve(ethers.ZeroAddress,await rewardSource.getAddress()));
assert.equal(await upgraded.getRewardsReserveBalance(),ethers.parseEther('100'));
await tx(rewardSource.setReserve(ethers.parseEther('100000001')));
await reverts(upgraded.getCirculatingSupply());
await tx(rewardSource.setReserve(ethers.parseEther('100')));
const badRewards=await deploy('Mocks.sol','TestRewards',admin,[await addr(attacker)]);
await reverts(upgraded.setRewardsReserve(ethers.ZeroAddress,await badRewards.getAddress()));
assert.deepEqual([...await upgraded.getStakingMetrics()],[false,0n,0n,0n]);
const staking=await deploy('Mocks.sol','TestStaking',admin,[tokenAddress]);
const beforeStake=await upgraded.getCirculatingSupply();
await tx(upgraded.setStakingMetricsSource(await staking.getAddress()));
assert.deepEqual([...await upgraded.getStakingMetrics()],[true,ethers.parseEther('123'),7n,3n]);
assert.equal(await upgraded.getCirculatingSupply(),beforeStake);
await reverts(upgraded.connect(attacker).setStakingMetricsSource(ethers.ZeroAddress));
await tx(upgraded.setStakingMetricsSource(ethers.ZeroAddress));
await tx(upgraded.setRewardsReserve(ethers.ZeroAddress,ethers.ZeroAddress));
assert.equal(await upgraded.getCirculatingSupply(),initialCirculating);

// Fresh V3 proxy initializes reserve accounting atomically, without a setup window.
const reserveInit=new ethers.Interface(abi).encodeFunctionData('initialize',[
    await addr(admin),tokenAddress,ethers.parseEther('100000000'),ethers.ZeroAddress,
    ethers.ZeroAddress,ethers.ZeroAddress,[],await addr(safe),ethers.ZeroAddress
]);
const reserveProxy=await deploy('@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol','ERC1967Proxy',admin,[await impl.getAddress(),reserveInit]);
const reserved=new ethers.Contract(await reserveProxy.getAddress(),abi,admin);
assert.equal(await reserved.rewardsReserveWallet(),await addr(safe));
assert.equal(await reserved.getCirculatingSupply(),await token.totalSupply()-await token.balanceOf(await addr(safe)));
await reverts(reserved.setRewardsReserve(ethers.ZeroAddress,await addr(attacker)));
await reverts(reserved.setRewardsReserve(await reserved.getAddress(),ethers.ZeroAddress));
await reverts(reserved.setRewardsReserve(tokenAddress,ethers.ZeroAddress));
const badStaking=await deploy('Mocks.sol','TestStaking',admin,[await addr(attacker)]);
await reverts(reserved.setStakingMetricsSource(await badStaking.getAddress()));
await reverts(reserved.setStakingMetricsSource(await addr(attacker)));
await tx(reserved.setRewardsReserve(ethers.ZeroAddress,await rewardSource.getAddress()));
await reverts(reserved.setDaoWallet(await rewardSource.getAddress()));
await tx(reserved.setRewardsReserve(await second.getAddress(),ethers.ZeroAddress));
await reverts(reserved.addVestingFactory(await second.getAddress()));
await tx(reserved.setRewardsReserve(ethers.ZeroAddress,ethers.ZeroAddress));
await tx(factory.setDeployedVesting(await addr(attacker)));
await tx(reserved.addVestingFactory(await factory.getAddress()));
await reverts(reserved.setRewardsReserve(await addr(attacker),ethers.ZeroAddress));
await reverts(reserved.setDaoWallet(await addr(attacker)));
const overlapFactory=await deploy('Mocks.sol','TestFactory',admin,[tokenAddress]);
await tx(overlapFactory.setDeployedVesting(await addr(safe)));
await tx(reserved.setRewardsReserve(await addr(safe),ethers.ZeroAddress));
await reverts(reserved.addVestingFactory(await overlapFactory.getAddress()));
const overlappingInit=new ethers.Interface(abi).encodeFunctionData('initialize',[
    await addr(admin),tokenAddress,ethers.parseEther('100000000'),ethers.ZeroAddress,
    await addr(safe),ethers.ZeroAddress,[],await addr(safe),ethers.ZeroAddress
]);
await reverts(deploy('@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol','ERC1967Proxy',admin,[await impl.getAddress(),overlappingInit]));

console.log('PASS: rewards wallet/source, reserve payouts, overlap/access guards, invalid accounting, staking metrics remain circulating.');
console.log('PASS: Cancun compile and proxy tests: atomic initializer, roles and upgrade, burn/supply invariant, Safe/DAO accounting, multi-factory aggregation, LP reporting, voting exclusion');

async function deploy(file,name,signer,args=[]) {
    const a=artifact(file,name);
    const c=await new ethers.ContractFactory(a.abi,a.evm.bytecode.object,signer).deploy(...args);
    await c.waitForDeployment();
    return c;
}
async function tx(p) { await (await p).wait(); }
async function reverts(p) {
    await assert.rejects(async()=>{
        const result = await p;
        if (result && typeof result.wait === 'function') await result.wait();
    });
}
