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
    return value * 3600 * 24 * 7;
}

function expectArgsEqual() {
    let args = [...arguments]
    for (i = 0; i < args.length - 1; i++) {
        expect(args[i]).to.be.equal(args[i + 1]);
    }
}

describe("Staking Test for Utku", function () {
    let owner, addr1, addr2, punishment;
    let Token, Pera, OthToken, MoreToken;
    let PWStaking, Staking;
    const STAKE_POOL = ethers.utils.parseUnits("100", 18);
    const DISTR_AMOUNT = 500;

    before(async function () {
        [owner, addr1, addr2, punishment] = await ethers.getSigners();

        Token = await ethers.getContractFactory("MockToken");
        Pera = await Token.deploy();
        OthToken = await Token.deploy();

        PWStaking = await ethers.getContractFactory("PeraStaking");
        Staking = await PWStaking.deploy(Pera.address, punishment.address, 2, "999999999999999");

        await Pera.connect(owner).approve(Staking.address, ethers.constants.MaxUint256);
        await Pera.connect(addr1).approve(Staking.address, ethers.constants.MaxUint256);
        await Pera.connect(addr2).approve(Staking.address, ethers.constants.MaxUint256);
        await Pera.connect(owner).transfer(addr1.address, DISTR_AMOUNT);
        await Pera.connect(owner).transfer(addr2.address, DISTR_AMOUNT);
        await Staking.connect(owner).depositRewardTokens("0", STAKE_POOL);

        await OthToken.connect(owner).approve(Staking.address, ethers.constants.MaxUint256);

        await Staking.connect(owner).changeStakeStatus();
    });

    it("pre-reqs", async function () {
        expect(Pera.address).to.be.properAddress;
        expect(Staking.address).to.be.properAddress;
        expect(OthToken.address).to.be.properAddress;
        expect(await Pera.balanceOf(Staking.address)).to.be.equal(STAKE_POOL);
    });

    describe("Staking", function () {
        let totalStaked, wTotalStaked;
        let userT1Balances = [0, 0];
        let userT2Balances = [0, 0];
        let initialTimestamp;

        before(async function () {
            await network.provider.send("evm_setAutomine", [false]);
            initialTimestamp = await getBlockTimestamp();
            userT1Balances[0] = await Pera.balanceOf(addr1.address);
            userT1Balances[1] = await Pera.balanceOf(addr2.address);
            userT2Balances[0] = await OthToken.balanceOf(addr1.address);
            userT2Balances[1] = await OthToken.balanceOf(addr2.address);
            await provider.send('evm_mine');
        });

        beforeEach(async function () {
            totalStaked = Number(await Staking.totalStaked());
            wTotalStaked = Number(await Staking.wTotalStaked());
            userT1Balances[0] = Number(await Pera.balanceOf(addr1.address));
            userT1Balances[1] = Number(await Pera.balanceOf(addr2.address));
            userT2Balances[0] = Number(await OthToken.balanceOf(addr1.address));
            userT2Balances[1] = Number(await OthToken.balanceOf(addr2.address));
        });

        it("t = 2", async function () {
            await provider.send('evm_setNextBlockTimestamp', [initialTimestamp + 2]);
            await Staking.connect(addr1).initialStake(500, 14);
            await provider.send('evm_mine');

            expect(Number(await Staking.totalStaked())).to.be.equal(500);
            expect(Number(await Staking.wTotalStaked())).to.be.equal(500 * 2000);
            expect(userT1Balances[0] - 500).to.be.equal(Number(await Pera.balanceOf(addr1.address)));
        });

        it("t = 4", async function () {
            await provider.send('evm_setNextBlockTimestamp', [initialTimestamp + 4]);
            await Staking.connect(owner).addNewRewardToken(OthToken.address, 4, (initialTimestamp + 12), "18");
            await Staking.connect(owner).depositRewardTokens("1", ethers.utils.parseUnits("32", 18));
            await provider.send('evm_mine');
            expect(Number(await OthToken.balanceOf(Staking.address))).to.be.equal(Number(ethers.utils.parseUnits("32", 18)));
        });

        it("t = 6", async function () {
            await provider.send('evm_setNextBlockTimestamp', [initialTimestamp + 6]);
            await Staking.connect(addr2).initialStake(500, 2);
            await provider.send('evm_mine');

            expect(Number(await Staking.totalStaked())).to.be.equal(1000);
            expect(Number(await Staking.wTotalStaked())).to.be.equal(1000 * 2000);
            expect(userT1Balances[1] - 500).to.be.equal(Number(await Pera.balanceOf(addr2.address)));
        });

        it("t = 8", async function () {
            await provider.send('evm_setNextBlockTimestamp', [initialTimestamp + 8]);
            await Staking.connect(addr2).withdraw();
            await Staking.connect(addr2).claimAllRewards();
            await provider.send('evm_mine');

            expect(Number(await Staking.totalStaked())).to.be.equal(500);
            expect(Number(await Staking.wTotalStaked())).to.be.equal(500 * 2000);
            expect(userT1Balances[1] + 502).to.be.equal(Number(await Pera.balanceOf(addr2.address)));
            expect(userT2Balances[1] + 4).to.be.equal(Number(await OthToken.balanceOf(addr2.address)));
        });

        it("t = 16", async function () {
            await provider.send('evm_setNextBlockTimestamp', [initialTimestamp + 16]);
            await Staking.connect(addr1).withdraw();
            await Staking.connect(addr1).claimAllRewards();
            await provider.send('evm_mine');
                        
            expect(Number(await Staking.totalStaked())).to.be.equal(0);
            expect(Number(await Staking.wTotalStaked())).to.be.equal(0);
            expect(userT1Balances[0] + 526).to.be.equal(Number(await Pera.balanceOf(addr1.address)));
            expect(userT2Balances[0] + 28).to.be.equal(Number(await OthToken.balanceOf(addr1.address)));
        });
    });

});


/*
    t  | totalStaked | totalWStaked | u1 stakes | u2 stakes | r1 rate | r2 rate | claim1 | claim2
    0    0             0              0           0           2         0         0+0      0+0
    2    500           1000           500         0           2         0         0+0      0+0
    4    500           500            500         0           2         4         0+0      0+0
    6    1000          2000           500         500         2         8         0+0      0+0
    8    500           500            500         0           2         8         0+0      2+4
    12   500           500            500         0           2         0         0+0      0+0
    16   0             0              0           0           2         0         26+28    0+0
 */