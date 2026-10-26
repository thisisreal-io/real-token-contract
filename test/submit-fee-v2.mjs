import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import solc from 'solc';
import { ethers } from 'ethers';

const root = path.resolve(import.meta.dirname, '..');
const source = fs.readFileSync(path.join(root, 'SubmitFeeV2.sol'), 'utf8');
const mocks = `// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
contract TestBurnable {
    mapping(address=>uint256) public balanceOf;
    mapping(address=>mapping(address=>uint256)) public allowance;
    uint256 public totalSupply;
    bool public failBurn;
    bool public attack;
    bool public reentrySucceeded;
    event Transfer(address indexed from,address indexed to,uint256 value);
    function mint(address to,uint256 amount) external {balanceOf[to]+=amount;totalSupply+=amount;}
    function approve(address spender,uint256 amount) external returns(bool){allowance[msg.sender][spender]=amount;return true;}
    function setFailBurn(bool value) external {failBurn=value;}
    function setAttack(bool value) external {attack=value;}
    function burnFrom(address who,uint256 amount) external {
        require(!failBurn,"Mock burn failure");
        if(attack){
            (reentrySucceeded,)=msg.sender.call(abi.encodeWithSignature("submit(uint8,string,bytes32)",uint8(3),"reentrant",bytes32(uint256(999))));
        }
        require(allowance[who][msg.sender]>=amount,"Allowance");
        require(balanceOf[who]>=amount,"Balance");
        allowance[who][msg.sender]-=amount;balanceOf[who]-=amount;totalSupply-=amount;
        emit Transfer(who,address(0),amount);
    }
}`;
const input={language:'Solidity',sources:{'SubmitFeeV2.sol':{content:source},'Mocks.sol':{content:mocks}},settings:{optimizer:{enabled:true,runs:200},evmVersion:'shanghai',outputSelection:{'*':{'*':['abi','evm.bytecode.object']}}}};
const output=JSON.parse(solc.compile(JSON.stringify(input),{import:name=>{
    const normalized=name.replace('@openzeppelin/contracts@5.1.0/','@openzeppelin/contracts/');
    try{return {contents:fs.readFileSync(path.join(root,'node_modules',normalized),'utf8')};}
    catch{return {error:`Missing import ${name}; run npm install`};}
}}));
assert.deepEqual((output.errors||[]).filter(error=>error.severity==='error').map(error=>error.formattedMessage),[]);
const rpc=process.env.REAL_SUBMIT_FEE_TEST_RPC || 'http://127.0.0.1:18549';
assert.ok(['127.0.0.1','localhost','[::1]'].includes(new URL(rpc).hostname),'Tests only use a local disposable chain.');
const provider=new ethers.JsonRpcProvider(rpc);
provider.pollingInterval=50;
const admin=await provider.getSigner(0), user=await provider.getSigner(1);
const deploy=async(file,name,args=[])=>{
    const artifact=output.contracts[file][name];
    const contract=await new ethers.ContractFactory(artifact.abi,artifact.evm.bytecode.object,admin).deploy(...args);
    await contract.waitForDeployment();return contract;
};
const token=await deploy('Mocks.sol','TestBurnable');
const fee=await deploy('SubmitFeeV2.sol','SubmitFeeV2',[await token.getAddress()]);
const feeAddress=await fee.getAddress(), userAddress=await user.getAddress();
const amount=ethers.parseEther('1');
const backendId=n=>ethers.zeroPadValue(ethers.toBeHex(n),32);
const mine=async tx=>await (await tx).wait();
const rejects=async action=>{await assert.rejects(async()=>{const result=await action();if(result?.wait)await result.wait();});};
await rejects(()=>deploy('SubmitFeeV2.sol','SubmitFeeV2',[ethers.ZeroAddress]));
assert.equal(await fee.REAL_TOKEN(),await token.getAddress());assert.equal(await fee.SUBMISSION_FEE(),amount);
await mine(token.mint(userAddress,20n*amount));
await mine(token.connect(user).approve(feeAddress,20n*amount));
for(const [type,title] of [[0,'Property'],[1,'Legacy forum'],[2,'Legacy poll'],[3,'Company']]){
    const id=backendId(type+1), before=await token.balanceOf(userAddress), supply=await token.totalSupply();
    const receipt=await mine(fee.connect(user).submit(type,title,id));
    const event=receipt.logs.map(log=>{try{return fee.interface.parseLog(log);}catch{return null;}}).find(event=>event?.name==='Submitted');
    assert.ok(event);assert.equal(event.args.submitter,userAddress);assert.equal(event.args.submissionType,BigInt(type));
    assert.equal(event.args.backendId,id);assert.equal(event.args.title,title);
    assert.equal(await token.balanceOf(userAddress),before-amount);assert.equal(await token.totalSupply(),supply-amount);
    assert.equal(await fee.usedBackendIds(id),true);
}
const balance=await token.balanceOf(userAddress);
await rejects(()=>fee.connect(user).submit(3,'Duplicate',backendId(4)));
assert.equal(await token.balanceOf(userAddress),balance);
await rejects(()=>fee.connect(user).submit(3,'',backendId(5)));
await rejects(()=>fee.connect(user).submit(3,'Company',ethers.ZeroHash));
await rejects(()=>fee.connect(user).submit(4,'Invalid enum',backendId(5)));
assert.equal(await fee.usedBackendIds(backendId(5)),false);
await mine(token.connect(user).approve(feeAddress,0));
await rejects(()=>fee.connect(user).submit(3,'No allowance',backendId(6)));
assert.equal(await fee.usedBackendIds(backendId(6)),false);
await mine(token.connect(user).approve(feeAddress,20n*amount));
const empty=await provider.getSigner(2);await mine(token.connect(empty).approve(feeAddress,amount));
await rejects(()=>fee.connect(empty).submit(3,'No balance',backendId(6)));
await mine(token.setFailBurn(true));
await rejects(()=>fee.connect(user).submit(3,'Burn fails',backendId(7),{gasLimit:300000}));
assert.equal(await fee.usedBackendIds(backendId(7)),false);assert.equal(await token.balanceOf(userAddress),balance);
await mine(token.setFailBurn(false));
await mine(fee.connect(user).submit(3,'Retry after failure',backendId(7)));
await mine(token.setAttack(true));
await mine(fee.connect(user).submit(3,'Reentrancy check',backendId(8),{gasLimit:300000}));
assert.equal(await token.reentrySucceeded(),false);assert.equal(await fee.usedBackendIds(backendId(999)),false);
provider.destroy();
console.log('SubmitFeeV2 checks passed: category codes0–3, exact burn/event, constructor validation, replay/invalid-input protection, allowance/balance, failed-burn rollback/retry and reentrancy.');
