// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract MetaNodeStake is 
        Initializable,  
        UUPSUpgradeable,
        PausableUpgradeable,
        AccessControlUpgradeable 
    {
        using Math for uint256;
        using SafeERC20 for IERC20;

        uint256 public startBlock;     // 开始区块
        uint256 public endBlock;       // 结束区块  
        uint256 public MetaNodePerBlock; // 每区块奖励
        bool public withdrawPaused;    // 取回暂停
        bool public claimPaused;       // 领取暂停
        IERC20 public MetaNode;        // MetaNode代币
        uint256 public totalPoolWeight; // 总权重
        Pool[] public pool;            // 质押池数组
        mapping (uint256 => mapping (address => User)) public user; // 用户数据  资金池 id => 用户地址 => 用户信息

        //质押池信息结构体
        struct Pool {
                address stTokenAddress; //质押代币的地址
                uint256 poolWeight; //质押池的权重，影响奖励分配。
                uint256 lastRewardBlock; //最后一次计算奖励的区块号
                uint256 accMetaNodePerST; //每个质押代币累积的 RCC 数量
                uint256 stTokenAmount; //池中的总质押代币量
                uint256 minDepositAmount; //最小质押金额
                uint256 unstakeLockedBlocks; //解除质押的锁定区块数
        }

        //用户信息结构体
        struct User {
                uint256 stAmount; //用户质押的代币数量
                uint256 finishedMetaNode; //已分配的 MetaNode数量
                uint256 pendingMetaNode; //待领取的 MetaNode 数量
                UnstakeRequest[] requests; //解质押请求列表，每个请求包含解质押数量和解锁区块
        }

        //取消质押请求结构体
        struct UnstakeRequest {
                uint256 amount; //用户取消质押的代币数量，要取出多少个 token
                uint256 unlockBlocks; // 解除质押的区块高度
        }

        bytes32 public constant UPGRADE_ROLE = keccak256("UPGRADE_ROLE");
        bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
        bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
        uint256 public constant ETH_PID = 0; //ETH 池的固定 ID 为 0

        event SetMetaNode(IERC20 indexed MetaNode);
        event SetMetaNodePerBlock(uint256 MetaNodePerBlock);

        event SetStartBlock(uint256 indexed startBlock);
        event SetEndBlock(uint256 indexed endBlock);

        event PauseWithdraw();
        event UnpauseWithdraw();
        event PauseClaim();
        event UnpauseClaim();

        event UpdatePoolInfo(uint256 indexed poolId, uint256 indexed minDepositAmount, uint256 indexed unstakeLockedBlocks);
        event UpdatePool(uint256 indexed poolId, uint256 indexed lastRewardBlock, uint256 totalMetaNode);
        event AddPool(address indexed stTokenAddress, uint256 indexed poolWeight, uint256 indexed lastRewardBlock, uint256 minDepositAmount, uint256 unstakeLockedBlocks);
        event SetPoolWeight(uint256 indexed poolId, uint256 indexed poolWeight, uint256 totalPoolWeight);

        event Deposit(address indexed user, uint256 indexed poolId, uint256 amount);
        event RequestUnstake(address indexed user, uint256 indexed poolId, uint256 amount);
        event Withdraw(address indexed user, uint256 indexed poolId, uint256 amount, uint256 indexed blockNumber);
        event Claim(address indexed user, uint256 indexed poolId, uint256 MetaNodeReward);
        
        modifier checkPid(uint256 _pid){
                require(_pid < pool.length, "invalid pid");
                _;
        }


        modifier whenNotClaimPaused() {
                require(!claimPaused, "claim is paused");
                _;
        }

        modifier whenNotWithdrawPaused() {
                require(!withdrawPaused, "withdraw is paused");
                _;
        }


                
        /**
         * @dev 初始化函数 设置奖励代币、开始结束区块、每区块奖励 初始化权限角色
         * @param _MetaNode MetaNode token地址
         * @param _startBlock 开始区块
         * @param _endBlock 结束区块 
         * @param _MetaNodePerBlock 每个区块的MetaNode奖励
         */
        function initialize(
                IERC20 _MetaNode,
                uint256 _startBlock,
                uint256 _endBlock,
                uint256 _MetaNodePerBlock
        ) public initializer {
                require(_startBlock <= _endBlock && _MetaNodePerBlock > 0, "invalid parameters");
                __AccessControl_init();
                __UUPSUpgradeable_init();
                _grantRole(PAUSER_ROLE, msg.sender);
                _grantRole(UPGRADE_ROLE, msg.sender);
                _grantRole(ADMIN_ROLE, msg.sender);

                setMetaNode(_MetaNode);

                startBlock = _startBlock;
                endBlock = _endBlock;
                MetaNodePerBlock = _MetaNodePerBlock;
        }


        function setMetaNode(IERC20 _MetaNode) public onlyRole(ADMIN_ROLE) {
                MetaNode = _MetaNode;

                emit SetMetaNode(MetaNode);
        }



        // ==============================================
        // 池子管理
        // ============================================== 

        /**- 添加新质押池
         * @param _stTokenAddress 质押代币地址
         * @param _poolWeight 池子权重
         * @param _minDepositAmount 最小质押数量
         * @param _unstakeLockedBlocks 取回锁定区块数(质押后经过多少个区块可以取回)
         * @param _withUpdate 是否更新池子信息
         */
        function addPool(address _stTokenAddress,uint256 _poolWeight,uint256 _minDepositAmount,uint256 _unstakeLockedBlocks,bool _withUpdate) public onlyRole(ADMIN_ROLE){
                //第一个池子必须是ETH池（地址为0），后续池子不能是0
                if(pool.length >0){
                        require(_stTokenAddress != address(0x0), "invalid staking token address");
                }else {
                        require(_stTokenAddress == address(0x0), "invalid staking token address");
                }
                require(_unstakeLockedBlocks > 0, "invalid withdraw locked blocks");
                require(block.number < endBlock, "Already ended");

                if (_withUpdate) {
                        massUpdatePools();
                }
                uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
                totalPoolWeight = totalPoolWeight + _poolWeight; 
                 pool.push(Pool({
                        stTokenAddress: _stTokenAddress,
                        poolWeight: _poolWeight,
                        lastRewardBlock: lastRewardBlock,
                        accMetaNodePerST: 0,
                        stTokenAmount: 0,
                        minDepositAmount: _minDepositAmount,
                        unstakeLockedBlocks: _unstakeLockedBlocks
                })); 

                emit AddPool(_stTokenAddress, _poolWeight, lastRewardBlock, _minDepositAmount, _unstakeLockedBlocks);     
        }

        //- 更新池子
        function updatePool(uint256 _pid) public checkPid(_pid) {
                Pool storage pool_  =  pool[_pid];

                if (block.number <= pool_.lastRewardBlock) {
                        return;
                }
                uint256 multiplier = getMultiplier(pool_.lastRewardBlock, block.number);
                (bool success1, uint256 totalMetaNode) = multiplier.tryMul(pool_.poolWeight);
                require(success1, "overflow");

                (success1, totalMetaNode) = totalMetaNode.tryDiv(totalPoolWeight);
                require(success1, "overflow");

                uint256 stSupply = pool_.stTokenAmount;   
                if (stSupply > 0) {
                        (bool success2, uint256 totalMetaNode_) = totalMetaNode.tryMul(1 ether);
                        require(success2, "overflow");

                        (success2, totalMetaNode_) = totalMetaNode_.tryDiv(stSupply);
                        require(success2, "overflow");

                        (bool success3, uint256 accMetaNodePerST) = pool_.accMetaNodePerST.tryAdd(totalMetaNode_);
                        require(success3, "overflow");
                        pool_.accMetaNodePerST = accMetaNodePerST;
                }

                pool_.lastRewardBlock = block.number;

                emit UpdatePool(_pid, pool_.lastRewardBlock, totalMetaNode);
        }

        //- 批量更新池子信息
        function massUpdatePools() public {
                uint256 length = pool.length;
                for (uint256 pid = 0; pid < length; pid++) {
                        updatePool(pid);
                }
        }


        function setPoolWeight(uint256 _pid, uint256 _poolWeight, bool _withUpdate) public onlyRole(ADMIN_ROLE) checkPid(_pid) {
                require(_poolWeight > 0, "invalid pool weight");
                
                if (_withUpdate) {
                        massUpdatePools();
                }

                totalPoolWeight = totalPoolWeight - pool[_pid].poolWeight + _poolWeight;
                pool[_pid].poolWeight = _poolWeight;

                emit SetPoolWeight(_pid, _poolWeight, totalPoolWeight);
        }


        // ==============================================
        // 核心业务逻辑
        // ============================================== 

        // - 质押 ETH（仅限池子0）
        function depositETH() public payable whenNotPaused() {
                Pool storage pool_ = pool[ETH_PID];
                require(pool_.stTokenAddress == address(0x0), "invalid staking token address");

                uint256 _amount = msg.value;
                require(_amount >= pool_.minDepositAmount, "deposit amount is too small");

                _deposit(ETH_PID, _amount);
        }


        // - 质押 ERC20 代币
        function deposit(uint256 _pid, uint256 _amount) public checkPid(_pid)  whenNotPaused() {
                Pool storage pool_ = pool[_pid];
                require(pool_.stTokenAddress != address(0x0), "invalid staking token address");
                require(_amount >= pool_.minDepositAmount, "deposit amount is too small");
                if(_amount > 0) {
                        IERC20(pool_.stTokenAddress).safeTransferFrom(msg.sender, address(this), _amount);
                }       
                _deposit(_pid, _amount);
        }

    
        /*
        * @dev 核心质押逻辑
        * @param _pid 质押池ID
        * @param _amount 质押数量
        */
        function _deposit(uint256 _pid, uint256 _amount) internal {
                Pool storage pool_ = pool[_pid];
                User storage user_ = user[_pid][msg.sender];

                //更新池子奖励
                //作用：确保奖励计算基于最新状态，包括：
                //更新 pool_.accMetaNodePerST（累计每单位质押奖励）
                //更新 pool_.lastRewardBlock（最后奖励区块）
                updatePool(_pid);

                //详情计算过程
                //accST = 用户当前质押量 × 当前累计奖励率 ÷ 1e18
                //pendingMetaNode_ = accST - 用户已结算奖励
                //如果 pendingMetaNode_ > 0，则累加到 user_.pendingMetaNode
                if (user_.stAmount > 0) {
                (bool success1, uint256 accST) = user_.stAmount.tryMul(pool_.accMetaNodePerST);
                require(success1, "user stAmount mul accMetaNodePerST overflow");
                (success1, accST) = accST.tryDiv(1 ether);
                require(success1, "accST div 1 ether overflow");
                
                (bool success2, uint256 pendingMetaNode_) = accST.trySub(user_.finishedMetaNode);
                require(success2, "accST sub finishedMetaNode overflow");

                if(pendingMetaNode_ > 0) {
                        (bool success3, uint256 _pendingMetaNode) = user_.pendingMetaNode.tryAdd(pendingMetaNode_);
                        require(success3, "user pendingMetaNode overflow");
                        user_.pendingMetaNode = _pendingMetaNode;
                }
                }

                //将新质押数量加到用户现有质押量上
                if(_amount > 0) {
                        (bool success4, uint256 stAmount) = user_.stAmount.tryAdd(_amount);
                        require(success4, "user stAmount overflow");
                        user_.stAmount = stAmount;
                }

                //更新池子总质押量
                (bool success5, uint256 stTokenAmount) = pool_.stTokenAmount.tryAdd(_amount);
                require(success5, "pool stTokenAmount overflow");
                pool_.stTokenAmount = stTokenAmount;


                //更新用户已结算奖励基准
                //重置用户的 finishedMetaNode，使其等于 新质押量 × 当前奖励率
                (bool success6, uint256 finishedMetaNode) = user_.stAmount.tryMul(pool_.accMetaNodePerST);
                require(success6, "user stAmount mul accMetaNodePerST overflow");

                (success6, finishedMetaNode) = finishedMetaNode.tryDiv(1 ether);
                require(success6, "finishedMetaNode div 1 ether overflow");

                user_.finishedMetaNode = finishedMetaNode;

                emit Deposit(msg.sender, _pid, _amount);
        }

        // - 发起取消质押请求（进入锁定期）
        function unstake(uint256 _pid, uint256 _amount) public whenNotPaused() checkPid(_pid) whenNotWithdrawPaused() {
                Pool storage pool_ = pool[_pid];
                User storage user_ = user[_pid][msg.sender];

                require(user_.stAmount >= _amount, "Not enough staking token balance");
                updatePool(_pid);

                // 计算待领取的奖励
                uint256 pendingMetaNode_ = user_.stAmount * pool_.accMetaNodePerST / (1 ether) - user_.finishedMetaNode;

                if(pendingMetaNode_ > 0) {
                        user_.pendingMetaNode = user_.pendingMetaNode + pendingMetaNode_;
                }

                 if(_amount > 0) {
                        user_.stAmount = user_.stAmount - _amount;
                        user_.requests.push(UnstakeRequest({
                                amount: _amount,
                                unlockBlocks: block.number + pool_.unstakeLockedBlocks
                        }));
                }

                pool_.stTokenAmount = pool_.stTokenAmount - _amount;
                user_.finishedMetaNode = user_.stAmount * pool_.accMetaNodePerST / (1 ether);

                emit RequestUnstake(msg.sender, _pid, _amount);
        }

        // - 取回已解锁的代币
        function withdraw(uint256 _pid) public  whenNotPaused() checkPid(_pid) whenNotWithdrawPaused()  {
                Pool storage pool_ = pool[_pid];
                User storage user_ = user[_pid][msg.sender];

                uint256 pendingWithdraw_;
                uint256 popNum_;

                for (uint256 i = 0; i < user_.requests.length; i++) {
                        if (user_.requests[i].unlockBlocks > block.number) {
                                break;
                        }
                        pendingWithdraw_ = pendingWithdraw_ + user_.requests[i].amount;
                        popNum_++;
                }

                for (uint256 i = 0; i < user_.requests.length - popNum_; i++) {
                        user_.requests[i] = user_.requests[i + popNum_];
                }

                for (uint256 i = 0; i < popNum_; i++) {
                        user_.requests.pop();
                }

                if (pendingWithdraw_ > 0) {
                        if (pool_.stTokenAddress == address(0x0)) {
                                _safeETHTransfer(msg.sender, pendingWithdraw_);
                        } else {
                                IERC20(pool_.stTokenAddress).safeTransfer(msg.sender, pendingWithdraw_);
                        }
                }

                emit Withdraw(msg.sender, _pid, pendingWithdraw_, block.number);
        }

        // - 领取奖励
        function claim(uint256 _pid) public  {
                Pool storage pool_ = pool[_pid];
                User storage user_ = user[_pid][msg.sender];

                updatePool(_pid);

                
                uint256 pendingMetaNode_ = user_.stAmount * pool_.accMetaNodePerST / (1 ether) - user_.finishedMetaNode + user_.pendingMetaNode;

                if(pendingMetaNode_ > 0) {
                        user_.pendingMetaNode = 0;
                        _safeMetaNodeTransfer(msg.sender, pendingMetaNode_);
                }

                user_.finishedMetaNode = user_.stAmount * pool_.accMetaNodePerST / (1 ether);

                emit Claim(msg.sender, _pid, pendingMetaNode_);
        }

        //- 查询待领取奖励
        function pendingMetaNode() public {

        }


        // ==============================================
        // 关键算法
        // ============================================== 

        /*计算从_from到_to的区块奖励乘数，即奖励的MetaNode数量
         * 计算公式：(to - from) * MetaNodePerBlock
         * 如果from小于startBlock，则以startBlock为准
         * 如果to大于endBlock，则以endBlock为准
         */
        function getMultiplier(uint256 _from, uint256 _to) public  view returns(uint256 multiplier) {
                require(_from <= _to, "invalid block");
                if (_from < startBlock) {
                        _from = startBlock;
                }
                if (_to > endBlock) {
                        _to = endBlock;
                }
                require(_from <= _to, "end block must be greater than start block");
        
                bool success;
                uint256 blockDifference = _to - _from;
                (success,multiplier) = blockDifference.tryMul(MetaNodePerBlock);
                require(success, "multiplier overflow");
        }



        // ==============================================
        // 系统设置
        // ==============================================  

        //- 设置每区块奖励
        function setMetaNodePerBlock(uint256 _MetaNodePerBlock) public onlyRole(ADMIN_ROLE) {
                require(_MetaNodePerBlock > 0, "invalid parameter");
                MetaNodePerBlock = _MetaNodePerBlock;
                emit SetMetaNodePerBlock(_MetaNodePerBlock);
        }

        //- 暂停取回
        function pauseWithdraw() public onlyRole(ADMIN_ROLE) {
                require(!withdrawPaused, "withdraw has been already paused");

                withdrawPaused = true;

                emit PauseWithdraw();
        }

        //- 恢复取回
        function unpauseWithdraw() public onlyRole(ADMIN_ROLE) {
                require(withdrawPaused, "withdraw has been already unpaused");
                withdrawPaused = false;
                emit UnpauseWithdraw();
        }

        // - 暂停领取 
        function pauseClaim() public onlyRole(ADMIN_ROLE){
                require(!claimPaused, "claim has been already paused");
                claimPaused = true;
                emit PauseClaim();
        }

        //- 恢复领取 
        function unpauseClaim() public onlyRole(ADMIN_ROLE) {
                require(claimPaused, "claim has been already unpaused");

                claimPaused = false;

                emit UnpauseClaim();
        }


        //- 设置开始区块
        function setStartBlock(uint256 _startBlock) public onlyRole(ADMIN_ROLE) {
                require(_startBlock <= endBlock, "start block must be smaller than end block");

                startBlock = _startBlock;

                emit SetStartBlock(_startBlock);
        }

        //- 设置结束区块
        function setEndBlock(uint256 _endBlock) public onlyRole(ADMIN_ROLE) {
                require(startBlock <= _endBlock, "start block must be smaller than end block");

                endBlock = _endBlock;

                emit SetEndBlock(_endBlock);
        }




        // 升级授权逻辑 (主要是检查权限 具体的升级逻辑在 UUPSUpgradeablel合约里面)
        function _authorizeUpgrade(address newImplementation) internal override  onlyRole(UPGRADE_ROLE){

        }


        function _safeETHTransfer(address _to, uint256 _amount) internal {
                (bool success, bytes memory data) = address(_to).call{
                value: _amount
                }("");

                require(success, "ETH transfer call failed");
                //  如果有返回数据，检查操作是否真正成功
                if (data.length > 0) {
                        require(
                                abi.decode(data, (bool)),
                                "ETH transfer operation did not succeed"
                        );
                }
        }

        function _safeMetaNodeTransfer(address _to, uint256 _amount) internal {
                uint256 MetaNodeBal = MetaNode.balanceOf(address(this));

                if (_amount > MetaNodeBal) {
                        MetaNode.transfer(_to, MetaNodeBal);
                } else {
                        MetaNode.transfer(_to, _amount);
                }
        }
    }