const { expect } = require("chai");
const { ethers,deployments } = require("hardhat");

describe("MetaNodeStake Tests", function () {
    let meteNode,metaNodeStake;
    let meteNodeAddress,metaNodeStakeAddress;
    let deployer,user1;

    beforeEach(async function () {
        const accounts = await getNamedAccounts();
        deployer = await ethers.getSigner(accounts.deployer);
        const signers = await ethers.getSigners();
        user1 = accounts.user1 ? await ethers.getSigner(accounts.user1) : signers[1];

        // fixture 会在本地链上执行部署脚本，返回部署结果 会自动调用deploy下的部署脚本
        await deployments.fixture(["MeteNode", "MetaNodeStake"]);

        //1.获取合约部署信息
        const meteNodeDeployer =  await deployments.get("MeteNode");
        const metaNodeStakeDeployer = await deployments.get("MetaNodeStake");

        //2.获取合约实例
        meteNode = await ethers.getContractAt("MeteNode", meteNodeDeployer.address);
        metaNodeStake = await ethers.getContractAt("MetaNodeStake", metaNodeStakeDeployer.address); // 返回 Proxy 地址
     
        meteNodeAddress = await meteNode.getAddress();
        metaNodeStakeAddress = await metaNodeStake.getAddress();
        // console.log("metaNodeStake address:", await metaNodeStake.getAddress());
        // console.log("meteNode address:", await meteNode.getAddress());
        // console.log("user1:", user1.address);

        // 给用户分发 token
        await meteNode.transfer(user1.address, ethers.parseEther("1000"));
    })

    it("部署者初始余额正确", async function () {
        const balance = await meteNode.balanceOf(deployer);
        expect(balance).to.be.gt(0);
    });

    it("用户可以存入代币并领取奖励", async function () {
        // ✅ 第一个池子必须是 ETH
        await metaNodeStake.addPool(
            ethers.ZeroAddress, // ETH 池
            100,                          // poolWeight
            ethers.parseEther("1"), // minDepositAmount
            1,                            // unstakeLockedBlocks
            true                          // withUpdate
        );

        //添加质押池
        await metaNodeStake.addPool(meteNodeAddress, 100, ethers.parseEther("1"), 1, true);
        //用户批准合约花费他们的代币
        await meteNode.connect(user1).approve(metaNodeStakeAddress, ethers.parseEther("100"));

        //用户user1 质押
        await metaNodeStake.connect(user1).deposit(1, ethers.parseEther("100"));
        //模拟区块推进 "0x5" → 前进 5 个区块
        await ethers.provider.send("hardhat_mine", ["0x5"]); 

        //取出奖励
        await metaNodeStake.connect(user1).claim(1);

        const balance = await meteNode.balanceOf(user1.address);
        expect(balance).to.be.gt(ethers.parseEther("900")); // 奖励到账
    });

    it("非管理员不能修改 MetaNode 地址", async function () {
        await expect(
            metaNodeStake.connect(user1).setMetaNode(meteNodeAddress)
        ).to.be.revertedWithCustomError(metaNodeStake, "AccessControlUnauthorizedAccount")
         .withArgs(user1.address, await metaNodeStake.ADMIN_ROLE());

    });

    it("用户可解除质押并提取代币", async function () {
         // ✅ 第一个池子必须是 ETH
        await metaNodeStake.addPool(
            ethers.ZeroAddress, // ETH 池
            100,                          // poolWeight
            ethers.parseEther("1"), // minDepositAmount
            1,                            // unstakeLockedBlocks
            true                          // withUpdate
        );
        await metaNodeStake.addPool(meteNodeAddress, 100, ethers.parseEther("1"), 5, true);
        await meteNode.connect(user1).approve(metaNodeStakeAddress, ethers.parseEther("100"));
        await metaNodeStake.connect(user1).deposit(1, ethers.parseEther("100"));

        await metaNodeStake.connect(user1).unstake(1, ethers.parseEther("50"));

        await ethers.provider.send("hardhat_mine", ["0x5"]); // 等待锁定区块

        await metaNodeStake.connect(user1).withdraw(1);
        const balance = await meteNode.balanceOf(user1.address);
        expect(balance).to.be.gte(ethers.parseEther("950"));
    });

    it("多次存入可累积奖励", async function () {
         // ✅ 第一个池子必须是 ETH
        await metaNodeStake.addPool(
            ethers.ZeroAddress, // ETH 池
            100,                          // poolWeight
            ethers.parseEther("1"), // minDepositAmount
            1,                            // unstakeLockedBlocks
            true                          // withUpdate
        );
        await metaNodeStake.addPool(meteNodeAddress, 100, ethers.parseEther("1"), 1, true);
        await meteNode.connect(user1).approve(metaNodeStakeAddress, ethers.parseEther("200"));

        await metaNodeStake.connect(user1).deposit(1, ethers.parseEther("100"));
        await ethers.provider.send("hardhat_mine", ["0x5"]);

        await metaNodeStake.connect(user1).deposit(1, ethers.parseEther("100"));
        await ethers.provider.send("hardhat_mine", ["0x5"]);

        await metaNodeStake.connect(user1).claim(1);
        const balance = await meteNode.balanceOf(user1.address);
        expect(balance).to.be.gt(ethers.parseEther("800"));
    });
})