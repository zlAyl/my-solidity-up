// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8;

import  "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import  "@openzeppelin/contracts/access/Ownable.sol";
import  "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import  "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

contract ShibStyleMemeToken is ERC20,Ownable {
    // 代币税相关变量
    uint256 public buyTaxRate;  // 买入税率
    uint256 public sellTaxRate;  // 卖出税率
    uint256 public transferTaxRate; //转账税
    address public taxWallet;   //税费接收地址（用于项目开发、营销等）
    address public liquidityWallet; //流动性资金(LP token)接收地址 此地址用来接受添加流动性后 返回得LP token
    uint256 public taxDistributionToLiquidity; // 分配给流动性的税费比例（100 = 1%）

    //交易限制相关变量
    uint256 public maxTransactionAmount; // 单笔交易最大数量
    uint256 public maxWalletBalance;     // 单个地址最大持仓量
    uint256 public tradeCooldown;        // 交易冷却时间（秒）
    bool public tradingEnabled;          // 交易是否开启
    bool public limitsEnabled;           // 限制是否启用

    // 流动性池相关变量
    IUniswapV2Router02 public uniswapV2Router;      // Uniswap V2 路由器地址
    address public uniswapV2Pair;        // Uniswap V2 交易对地址(流动性池的地址)
    bool public inSwapAndLiquify;        // 防止重入的锁标志
    bool public swapAndLiquifyEnabled;   // 自动添加流动性是否启用
    uint256 public minTokensToLiquify;   // 触发自动添加流动性的最小代币数量

    // 映射和修饰器相关
    mapping(address => bool) private _isExcludedFromTax;    // 免税地址映射
    mapping(address => bool) private _isExcludedFromLimits; // 免限制地址映射
    mapping(address => uint256) private _lastTradeTime;     // 最后交易时间映射

    /**
     * @dev 税率更新事件
     * @param buyTax 新的买入税率
     * @param sellTax 新的卖出税率
     * @param transferTax 新的转账税率
     */
    event TaxRatesUpdated(uint256 buyTax, uint256 sellTax, uint256 transferTax);

    /**
     * @dev 税费钱包更新事件
     * @param taxWallet 新的税费钱包地址
     * @param liquidityWallet 新的流动性钱包地址
     */
    event TaxWalletsUpdated(address taxWallet, address liquidityWallet);


    /**
     * @dev 税费分配事件
     * @param taxAmount 税费总额
     * @param liquidityAmount 分配给流动性的金额
     * @param taxWalletAmount 分配给税费钱包的金额
     */
    event TaxDistributed(uint256 taxAmount, uint256 liquidityAmount, uint256 taxWalletAmount);


     /**
     * @dev 流动性添加事件
     * @param tokensSwapped 交换的代币数量
     * @param ethReceived 收到的ETH数量
     * @param tokensIntoLiquidity 添加到流动性的代币数量
     */
    event SwapAndLiquify(uint256 tokensSwapped, uint256 ethReceived, uint256 tokensIntoLiquidity);

    /**
     * @dev 添加交易冷却时间
     * @param cooldown 交易冷却时间
     */
    event CooldownUpdated(uint256 cooldown);


    /**
     * @dev 设置交易限制事件
     * @param maxTransaction 单笔交易最大数量    
     * @param maxWallet 单个地址最大持仓量
     */
    event TransactionLimitsUpdated(uint256 maxTransaction, uint256 maxWallet);


    /**
    * @dev 是否启用交易事件
    * @param enabled 是否开启 
    */  
    event TradingEnabledUpdated(bool enabled);


    /**
     * @dev 防止在交换和添加流动性过程中重入的修饰器
     */
    modifier lockTheSwap() {
        inSwapAndLiquify = true;
        _;
        inSwapAndLiquify = false;
    }

    /**
     * @dev 检查交易是否启用的修饰器
     */
    modifier tradingCheck(address from, address to) {
        require(
            tradingEnabled || 
            from == owner() || 
            to == owner() || 
            from == address(this) || 
            _isExcludedFromLimits[from] || 
            _isExcludedFromLimits[to],
            "Trading is not enabled yet"
        );
        _;
    }

    /**
     * @dev 构造函数，初始化代币
     * @param name 代币名称
     * @param symbol 代币符号
     * @param totalTokenSupply 代币总供应量
     * @param uniswapRouterAddress Uniswap路由器地址
     * @param taxReceiverWallet 税费接收地址
     * @param liquidityReceiverWallet 流动性资金接收地址
     */
    constructor(string memory name,string memory symbol, uint256 totalTokenSupply, address uniswapRouterAddress,address taxReceiverWallet, address liquidityReceiverWallet) ERC20(name,symbol) Ownable(msg.sender)  {
          // 铸造全部代币给合约部署者
        _mint(msg.sender, totalTokenSupply);

        // 初始化税率设置（使用基点，100 = 1%）
        buyTaxRate = 200;        // 2% 买入税
        sellTaxRate = 500;       // 5% 卖出税  
        transferTaxRate = 100;   // 1% 转账税

        // 设置税费接收地址
        taxWallet = taxReceiverWallet;
        liquidityWallet = liquidityReceiverWallet;
        taxDistributionToLiquidity = 5000; // 50%的税费用于流动性

        // 初始化交易限制
        maxTransactionAmount = totalTokenSupply * 1 / 100 ;  // 最大交易量：总供应量的1%
        maxWalletBalance = totalTokenSupply * 2 / 100;      // 最大持仓量：总供应量的2%
        tradeCooldown = 300;     // 交易冷却时间：5分钟
        tradingEnabled = false;  // 初始交易关闭
        limitsEnabled = true;    // 启用交易限制


        // 初始化流动性设置
        uniswapV2Router = IUniswapV2Router02(uniswapRouterAddress);
        uniswapV2Pair = IUniswapV2Factory(uniswapV2Router.factory())
            .createPair(address(this), uniswapV2Router.WETH());
        swapAndLiquifyEnabled = true;
        minTokensToLiquify = totalTokenSupply * 5 / 10000; // 0.05%的总供应量

        // 设置初始豁免地址
        _setInitialExemptions();
    }



    // ==============================================
    // 核心交易函数重写
    // ==============================================

    /**
     * @dev 重写transfer函数，加入税费和限制逻辑
     * @param to 接收方地址
     * @param amount 转账金额
     * @return 是否成功
     */
    function transfer(address to, uint256 amount) public virtual override tradingCheck(msg.sender, to) returns (bool) 
    {
        return _tokenTransfer(msg.sender, to, amount);
    }

     /**
     * @dev 重写transferFrom函数，加入税费和限制逻辑
     * @param from 发送方地址
     * @param to 接收方地址
     * @param amount 转账金额
     * @return 是否成功
     */
    function transferFrom(address from, address to, uint256 amount) public  override  tradingCheck(from, to) returns (bool) 
    {
        address spender = _msgSender();
        _spendAllowance(from, spender, amount);
        return _tokenTransfer(from, to, amount);
    }


    /**
     * @dev 核心转账逻辑，处理税费计算和分配
     * @param from 发送方地址
     * @param to 接收方地址
     * @param amount 转账金额
     * @return 是否成功
     */
    function _tokenTransfer(address from, address to, uint256 amount) private returns (bool) {
        // 1. 验证交易限制
        _validateTransfer(from, to, amount);
        
        // 2. 计算税费
        uint256 taxAmount = 0;
        if (!_isExcludedFromTax[from] && !_isExcludedFromTax[to]) {
            taxAmount = _calculateTaxAmount(from, to, amount);
        }
        
        uint256 transferAmount = amount - taxAmount;
        
        // 3. 执行转账
        _transfer(from, to, transferAmount);
        
        // 4. 处理税费
        if (taxAmount > 0) {
            _transfer(from, address(this), taxAmount); //把交易税转到当前合约
            _processTax(taxAmount); //分配税费
        }
        
        // 5. 更新交易时间
       // _updateTradeTime(from, to);
        
        return true;
    }


    /**
     * @dev 验证转账是否符合所有限制
     * @param from 发送方地址
     * @param to 接收方地址
     * @param amount 转账金额
     */
    function _validateTransfer(address from, address to, uint256 amount) private view {
        // 如果限制未启用或地址在免限制列表中，跳过检查
        if (!limitsEnabled || _isExcludedFromLimits[from] || _isExcludedFromLimits[to]) {
            return;
        }
        
        // 检查交易量限制
        if (from == uniswapV2Pair || to == uniswapV2Pair) {
            require(amount <= maxTransactionAmount, "Transfer amount exceeds max transaction");
        }
        
        // 检查持仓量限制（仅对普通转账和买入操作）
        if (to != uniswapV2Pair && to != address(0)) {
            uint256 newBalance = balanceOf(to) + amount;
            require(newBalance <= maxWalletBalance, "Wallet balance exceeds max wallet");
        }
        
        // 检查交易冷却时间
        if (from != uniswapV2Pair && !_isExcludedFromLimits[from]) {
            require(
                block.timestamp >= _lastTradeTime[from] + tradeCooldown,
                "Trade cooldown not expired"
            );
        }
    }

    /**
     * @dev 处理税费分配
     * @param taxAmount 税费总额
     */
    function _processTax(uint256 taxAmount) private {
        // 如果达到阈值且不在交换过程中，自动添加流动性
        uint256 contractTokenBalance = balanceOf(address(this));
        if (
            contractTokenBalance >= minTokensToLiquify &&
            !inSwapAndLiquify &&
            msg.sender != uniswapV2Pair &&
            swapAndLiquifyEnabled
        ) {
            _addLiquidityAutomatically(minTokensToLiquify);
        } else {
            // 否则直接分配税费
            _distributeTax(taxAmount);
        }
    }


    /**
     * @dev 根据交易类型计算税费
     * @param from 发送方地址
     * @param to 接收方地址
     * @param amount 交易金额
     * @return 税费金额
     */
    function _calculateTaxAmount(address from, address to, uint256 amount) private view returns (uint256) {
        if (from == uniswapV2Pair) {
            // 买入交易
            return _calculateTax(amount, buyTaxRate);
        } else if (to == uniswapV2Pair) {
            // 卖出交易
            return _calculateTax(amount, sellTaxRate);
        } else {
            // 普通转账
            return _calculateTax(amount, transferTaxRate);
        }
    }


    // ==============================================
    // 交易限制功能
    // ==============================================

     /**
     * @dev 启用或禁用交易
     * @param isEnabled 是否启用交易
     */
    function setTradingEnabled(bool isEnabled) external onlyOwner {
        tradingEnabled = isEnabled;
        emit TradingEnabledUpdated(isEnabled);
    }

    /**
     * @dev 设置交易限制
     * @param newMaxTransaction 单笔交易最大数量
     * @param newMaxWallet 单个地址最大持仓量
     */
    function setTransactionLimits(
        uint256 newMaxTransaction, 
        uint256 newMaxWallet
    ) external onlyOwner {
        //totalSupply() 代币得总供应量
        require(newMaxTransaction >= totalSupply() / 1000, "Max transaction too low");
        require(newMaxWallet >= totalSupply() / 1000, "Max wallet too low");
        
        maxTransactionAmount = newMaxTransaction;
        maxWalletBalance = newMaxWallet;
        
        emit TransactionLimitsUpdated(newMaxTransaction, newMaxWallet);
    }

    /**
     * @dev 设置交易冷却时间
     * @param newCooldown 冷却时间（秒）
     */
    function setTradeCooldown(uint256 newCooldown) external onlyOwner {
        require(newCooldown <= 3600, "Cooldown too long");
        tradeCooldown = newCooldown;
        emit CooldownUpdated(newCooldown);
    }


    /**
     * @dev 启用或禁用交易限制
     * @param isEnabled 是否启用限制
     */
    function setLimitsEnabled(bool isEnabled) external onlyOwner {
        limitsEnabled = isEnabled;
    }


    /**
     * @dev 将地址添加到免限制列表
     * @param account 要添加的地址
     */
    function excludeFromLimits(address account) external onlyOwner {
        _isExcludedFromLimits[account] = true;
    }
    
    /**
     * @dev 将地址从免限制列表中移除
     * @param account 要移除的地址
     */
    function includeInLimits(address account) external onlyOwner {
        _isExcludedFromLimits[account] = false;
    }


    /**
     * @dev 更新交易时间
     * @param from 发送方地址
     * @param to 接收方地址
     */
    function _updateTradeTime(address from, address to) private {
        if (from == uniswapV2Pair) { // 买入
            _lastTradeTime[to] = block.timestamp;
        } else if (to == uniswapV2Pair) { // 卖出
            _lastTradeTime[from] = block.timestamp;
        }
    }


    // ==============================================
    // 代币税功能实现
    // ==============================================

    /**
     * @dev 设置税率
     * @param _buyTax 买入税率（基点）
     * @param _sellTax 卖出税率（基点） 
     * @param _transferTax 转账税率（基点）
     */
    function setTaxRates(uint256 _buyTax, uint256 _sellTax, uint256 _transferTax) external onlyOwner {
        // 验证税率不超过25%（防止过高的税率）
        require(_buyTax <= 2500, "Buy tax too high");
        require(_sellTax <= 2500, "Sell tax too high"); 
        require(_transferTax <= 2500, "Transfer tax too high");
        
        buyTaxRate = _buyTax;
        sellTaxRate = _sellTax;
        transferTaxRate = _transferTax;
        
        emit TaxRatesUpdated(_buyTax, _sellTax, _transferTax);
    }

    /**
     * @dev 设置税费接收地址
     * @param _taxWallet 新的税费接收地址
     * @param _liquidityWallet 新的流动性资金接收地址
     */
    function setTaxWallets(address _taxWallet, address _liquidityWallet) external onlyOwner {
        require(_taxWallet != address(0), "Tax wallet cannot be zero address");
        require(_liquidityWallet != address(0), "Liquidity wallet cannot be zero address");
        
        taxWallet = _taxWallet;
        liquidityWallet = _liquidityWallet;
        
        emit TaxWalletsUpdated(_taxWallet, _liquidityWallet);
    }

    /**
     * @dev 设置流动性分配比例
     * @param _distribution 分配给流动性的比例（基点，10000 = 100%）
     */
    function setTaxDistribution(uint256 _distribution) external onlyOwner {
        require(_distribution <= 10000, "Distribution cannot exceed 100%");
        taxDistributionToLiquidity = _distribution;
    }

    /**
     * @dev 将地址添加到免税列表
     * @param account 要添加的地址
     */
    function excludeFromTax(address account) external onlyOwner {
        _isExcludedFromTax[account] = true;
    }

    /**
     * @dev 将地址从免税列表中移除
     * @param account 要移除的地址
     */
    function includeInTax(address account) external onlyOwner {
        _isExcludedFromTax[account] = false;
    }

     /**
     * @dev 计算税费金额
     * @param amount 交易金额
     * @param taxRate 税率
     * @return 税费金额
     */
    function _calculateTax(uint256 amount,  uint256 taxRate) private pure returns (uint256) {
        return amount * taxRate / 10000 ;
    }

    /**
     * @dev 分配税费
     * @param taxAmount 税费总额
     */
    function _distributeTax(uint256 taxAmount) private {
        // 计算分配给流动性的金额
        uint256 liquidityAmount = taxAmount * taxDistributionToLiquidity / 10000;
        uint256 taxWalletAmount = taxAmount - liquidityAmount;
        
        // 转移给税费钱包
        if (taxWalletAmount > 0) {
            _transfer(address(this), taxWallet, taxWalletAmount);
        }
        
        // 处理流动性部分
        if (liquidityAmount > 0) {
            _addLiquidityAutomatically(liquidityAmount);
        }
        
        emit TaxDistributed(taxAmount, liquidityAmount, taxWalletAmount);
    }

    /**
     * @dev 自动添加流动性
     * @param tokenAmount 代币数量
     */
    function _addLiquidityAutomatically(uint256 tokenAmount) private lockTheSwap {
        // 将代币分成两半
        uint256 half = tokenAmount / 2 ;
        uint256 otherHalf = tokenAmount - half;
        
        // 将一半代币兑换为ETH
        uint256 initialBalance = address(this).balance;  // 当前合约的ETH余额
        _swapTokensForEth(half); // 用代币兑换ETH，ETH会发送到当前合约
        uint256 newBalance = address(this).balance - initialBalance; // 兑换后合约的ETH余额
        
        // 添加流动性
        _addLiquidity(otherHalf, newBalance);
        
        emit SwapAndLiquify(half, newBalance, otherHalf);
    }


      /**
     * @dev 手动触发添加流动性（把合约本省累计的代币添加到流动性池）
     */
    function manualSwapAndLiquify() external onlyOwner {
        uint256 contractTokenBalance = balanceOf(address(this));
        require(contractTokenBalance >= minTokensToLiquify, "Token balance too low");
        _addLiquidityAutomatically(contractTokenBalance);
    }

    /**
     * @dev 将代币兑换为ETH
     * @param tokenAmount 代币数量
     */
    function _swapTokensForEth(uint256 tokenAmount) private {
        // 生成兑换路径
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();
        
        // 批准路由器使用代币
        _approve(address(this), address(uniswapV2Router), tokenAmount);
        
        // 执行兑换
        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // 接受任何数量的ETH
            path,
            address(this),
            block.timestamp
        );
    }

    /**
     * @dev 添加流动性
     * @param tokenAmount 代币数量
     * @param ethAmount ETH数量
     */
    function _addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {
        // 批准路由器使用代币
        _approve(address(this), address(uniswapV2Router), tokenAmount);
        
        
        // 添加流动性
       uniswapV2Router.addLiquidityETH{value: ethAmount}(
            address(this),  // 代币地址
            tokenAmount,     // 代币数量 
            0, // 滑点保护
            0, // 滑点保护
            liquidityWallet, // LP代币接收地址
            block.timestamp // 截止时间
        );
    }




    /**
     * @dev 设置初始豁免地址
     */
    function _setInitialExemptions() private {
        // 合约部署者和本合约地址免税费和限制
        _isExcludedFromTax[owner()] = true;
        _isExcludedFromTax[address(this)] = true;
        _isExcludedFromLimits[owner()] = true;
        _isExcludedFromLimits[address(this)] = true;
        
        // 税费接收地址和流动性钱包免限制
        _isExcludedFromLimits[taxWallet] = true;
        _isExcludedFromLimits[liquidityWallet] = true;
    }


    // 接收ETH函数
    receive() external payable {}
}