require("@nomicfoundation/hardhat-toolbox");
require("hardhat-deploy")
require("@openzeppelin/hardhat-upgrades");
require("dotenv").config();
/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: "0.8.28",
  networks:{
    hardhat: {
      saveDeployments: true, // 对于 hardhat 网络也要开启 用于保存部署结果到文件系统中 开启后 部署结果也会被保存到 deployments
    },
    localhost: {
      saveDeployments: true,
    },
    sepolia: {
      chainId: 11155111,
      url:`https://sepolia.infura.io/v3/${process.env.INFURA_API_KEY}`, //链接
      accounts: [process.env.PRIVATE_KEY],
      saveDeployments: true,
    },
  },
  namedAccounts: {
    deployer: {default : 0}, //部署账号
    user1: {default : 1},
   }
};
