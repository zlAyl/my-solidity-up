module.exports = async ({getNamedAccounts, deployments}) => {
    const {deploy} = deployments;
    const {deployer} = await getNamedAccounts();

    console.log("部署 MeteNode 合约...");

    try {
        const meteNode = await deploy('MeteNode',{
            from: deployer, 
            args: [],
            log: true,
        })
        console.log(`✅ MeteNode 合约部署成功，地址: ${meteNode.address}`);
    }catch(error){
        console.error('MeteNode 合约 部署失败:', error);
        throw error;
    }
}

module.exports.tags = ['MeteNode'];