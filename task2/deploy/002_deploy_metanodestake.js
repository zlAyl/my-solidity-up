const { ethers, upgrades } = require("hardhat");

module.exports = async ({getNamedAccounts, deployments }) => {
    const {deploy} = deployments;
    const {deployer} = await getNamedAccounts();

    console.log("部署 MetaNodeStake 合约...");

    try {
         // ✅ 获取已部署的 MeteNode 地址
        const meteNodeDeployment = await deployments.get("MeteNode");
        const meteNode =  await ethers.getContractAt("MeteNode",meteNodeDeployment.address)

        const meteNodeAddress = await meteNode.getAddress();

        console.log("MeteNode deployment:", meteNodeDeployment.address);
        console.log("meteNode:", await meteNode.getAddress());

        const signer = await ethers.getSigner(deployer);
        const MetaNodeStake = await ethers.getContractFactory("MetaNodeStake", signer);


        // ✅ 获取当前区块号（Sepolia 上）
        const currentBlock = await ethers.provider.getBlockNumber();

        // ✅ 设置奖励时间段（例如 1000 个区块）
        const startBlock = currentBlock +10;
        const endBlock = startBlock + 1000;
        const rewardPerBlock = ethers.parseEther("1");

        // ✅ 部署 MetaNodeStake(可升级合约的部署)
        const metaNodeStake = await upgrades.deployProxy(
            MetaNodeStake,
            [meteNodeAddress, startBlock, endBlock, rewardPerBlock],
            {
            initializer: "initialize",
            }
        );
        await metaNodeStake.waitForDeployment();


        const metaNodeStakeAddress = await metaNodeStake.getAddress();

        // 手动写入 deployments 供 fixture 使用
        //hardhat-deploy fixture 只跟踪 deploy()，不会自动跟踪 upgrades.deployProxy。
        //如果想在测试里用 fixture，就 要么用 deploy() + initialize()，要么手动写入部署信息。
        await deployments.save("MetaNodeStake", {
            address: metaNodeStakeAddress,
            abi: MetaNodeStake.interface.fragments,
        });

        // const stake = await deploy("MetaNodeStake", {
        //     from: deployer,
        //     log: true,
        //     args: [],
        // });
        console.log(`✅ MetaNodeStake 合约部署成功，地址: ${metaNodeStakeAddress}`);
    }catch(error){
        console.error('MetaNodeStake 合约 部署失败:', error);
        throw error;
    }
}

module.exports.tags = ["MetaNodeStake"];
module.exports.dependencies = ["MeteNode"];