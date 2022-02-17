const { expect } = require("chai");
const { ethers } = require("hardhat");
const provider = ethers.provider;

async function getBlockTimestamp() {
    let block_number, block, block_timestamp;

    block_number = await provider.getBlockNumber();;
    block = await provider.getBlock(block_number);
    block_timestamp = block.timestamp;

    return block_timestamp;
}

function weekToSecs(value) {
    return value * 3600*24*7;
}

function expectArgsEqual() {
    let args = [...arguments]
    for (i = 0; i < args.length - 1; i++) {
        expect(args[i]).to.be.equal(args[i + 1]);
    }
}

function ethToNumber(value) {
   return Number(ethers.utils.formatEther(value));
}

describe("Weighted Stakng Test", function () {
    let owner, addr1, addr2, punishment;
    let Token, Pera;
    let PWStaking, Staking;
    const STAKE_POOL = ethers.utils.parseUnits("3144960000", 18);
    const DISTR_AMOUNT = ethers.utils.parseUnits("500", 18);

    before (async function() {
        [owner, addr1, addr2, punishment] = await ethers.getSigners();

        Token = await ethers.getContractFactory("MockToken");
        Pera = await Token.deploy();

        PWStaking = await ethers.getContractFactory("PeraWeightedStaking");
        Staking = await PWStaking.deploy(Pera.address, punishment.address, ethers.utils.parseEther("100"));

        await Pera.connect(owner).approve(Staking.address, ethers.constants.MaxUint256);
        await Pera.connect(addr1).approve(Staking.address, ethers.constants.MaxUint256);
        await Pera.connect(addr2).approve(Staking.address, ethers.constants.MaxUint256);
        await Pera.connect(owner).transfer(addr1.address, DISTR_AMOUNT);
        await Pera.connect(owner).transfer(addr2.address, DISTR_AMOUNT);
        await Staking.connect(owner).depositRewardTokens(STAKE_POOL);
    });

    it("Deploys contracts", async function () {
        expect(Pera.address).to.be.properAddress;
        expect(Staking.address).to.be.properAddress;
    });

    // it("Distributes and Approves", async function () {
    //     for (let i = 0; i < addresses.length; i++) {
    //         expect(Number(ethers.utils.formatEther(await Pera.allowance(addresses[i].address, Staking.address)))).to.be.greaterThan(0);
    //         expect(Number(ethers.utils.formatEther(await Pera.balanceOf(addresses[i].address)))).to.be.greaterThan(0);
    //     }
    // });

    it("Deposits rewards", async function () {
        expect(await Pera.balanceOf(Staking.address)).to.be.equal(STAKE_POOL);
    });

    describe("Staking", function () {
        let totalStaked, wTotalStaked;
        let userTotalStaked = [0,0];
        let userWeights = [0,0];
        let userBalances = [0, 0];
        let initialTimestamp;

        beforeEach(async function () {
            userBalances[0] = ethToNumber(await Pera.balanceOf(addr1.address));
            userBalances[1] = ethToNumber(await Pera.balanceOf(addr2.address));
        });

        it("Stakes", async function () {
            await network.provider.send("evm_setAutomine", [false]);
            initialTimestamp = await getBlockTimestamp();
            await provider.send('evm_setNextBlockTimestamp', [initialTimestamp+1]);
            await Staking.connect(addr1).initialStake(ethers.utils.parseEther("100"), weekToSecs(52));
            await provider.send('evm_mine');
            userTotalStaked[0] = 100;
            totalStaked = 100;
            userWeights[0] = 200;
            wTotalStaked = 100*userWeights[0];
            expect(ethToNumber(await Pera.balanceOf(addr1.address))).to.be.equal(userBalances[0] - 100);
            expect(ethToNumber(await Staking.userStaked(addr1.address))).to.be.equal(userTotalStaked[0]);
            expect(ethToNumber(await Staking.totalStaked())).to.be.equal(totalStaked);
            expect(Number(await Staking.userWeights(addr1.address))).to.be.equal(userWeights[0]);
            expect(ethToNumber(await Staking.wTotalStaked())).to.be.equal(wTotalStaked);
        });

        it("Gets rewards", async function () {
            await provider.send('evm_setNextBlockTimestamp', [initialTimestamp + 6]);
            await Staking.connect(addr1).claimReward();
            await provider.send('evm_mine');
            expect(ethToNumber(await Pera.balanceOf(addr1.address))).to.be.equal(userBalances[0] + 500);
        });

        it("Gets rewards again, and new staker", async function () {
            await provider.send('evm_setNextBlockTimestamp', [initialTimestamp + 10]);
            await Staking.connect(addr1).claimReward();     
            await Staking.connect(addr2).initialStake(ethers.utils.parseEther("100"), weekToSecs(4));
            await provider.send('evm_mine');
            userTotalStaked[1] = 100;
            totalStaked += 100;
            userWeights[1] = 150;
            wTotalStaked += 100*userWeights[1];
            expect(ethToNumber(await Pera.balanceOf(addr1.address))).to.be.equal(userBalances[0] + 400);
            expect(ethToNumber(await Pera.balanceOf(addr2.address))).to.be.equal(userBalances[1] - 100);
            expect(ethToNumber(await Staking.userStaked(addr2.address))).to.be.equal(userTotalStaked[1]);
            expect(ethToNumber(await Staking.totalStaked())).to.be.equal(totalStaked);
            expect(Number(await Staking.userWeights(addr2.address))).to.be.equal(userWeights[1]);
            expect(ethToNumber(await Staking.wTotalStaked())).to.be.equal(wTotalStaked);
        });

        it("Calculates rewards for same passing time", async function () {
            await provider.send('evm_setNextBlockTimestamp', [initialTimestamp + 17]);
            await Staking.connect(addr1).claimReward();     
            await Staking.connect(addr2).claimReward();     
            await provider.send('evm_mine');
            expect(ethToNumber(await Pera.balanceOf(addr1.address))).to.be.equal(userBalances[0] + 400);
            expect(ethToNumber(await Pera.balanceOf(addr2.address))).to.be.equal(userBalances[1] + 300);
        });
    });
});