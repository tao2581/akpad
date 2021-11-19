// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./libs/BEP20.sol";

import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";

// PantherToken with Governance.
contract PantherToken is BEP20 {
    // Transfer total tax rate in basis points. (default 5%)
    uint16 public transferTaxRate = 500;
    // Markting rate % of transfer tax. (default 60% x 5% = 3% of total amount).
    uint16 public taxRate = 6000; // 60%
    // Max transfer tax rate: 15%.
    uint16 public constant MAXIMUM_TRANSFER_TAX_RATE = 1500;
    // Burn address
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    address public _marketingWalletAddress = 0xEe6bd41f4B61350e70a18B5CE394AaeBacbA65b0;
    // address public constant _pancakeRouter = 0xcc7adc94f3d80127849d2b41b6439b7cf1eb4ae0;
    // Max transfer amount rate in basis points. (default is 50% of total supply)
    uint16 public maxTransferAmountRate = 5000;
    // Addresses that excluded from antiWhale
    mapping(address => bool) private _excludedFromAntiWhale;
    // Automatic swap and liquify enabled
    bool public swapAndLiquifyEnabled = true;
    // Min amount to liquify. (default 500 PANTHERs)
    uint256 public minAmountToLiquify = 500 ether;
    // The swap router, modifiable. Will be changed to PantherSwap's router when our own AMM release
    IUniswapV2Router02 public pantherSwapRouter;
    // The trading pair
    address public pantherSwapPair;
    // In swap and liquify
    bool private _inSwapAndLiquify;

    // The operator can only update the transfer tax rate
    address private _operator;

    // Events
    event OperatorTransferred(address indexed previousOperator, address indexed newOperator);
    event TransferTaxRateUpdated(address indexed operator, uint256 previousRate, uint256 newRate);
    event TaxRateUpdated(address indexed operator, uint256 previousRate, uint256 newRate);
    event MaxTransferAmountRateUpdated(address indexed operator, uint256 previousRate, uint256 newRate);
    event SwapAndLiquifyEnabledUpdated(address indexed operator, bool enabled);
    event MinAmountToLiquifyUpdated(address indexed operator, uint256 previousAmount, uint256 newAmount);
    event PantherSwapRouterUpdated(address indexed operator, address indexed router, address indexed pair);
    event SwapAndLiquify(uint256 tokensSwapped, uint256 ethReceived, uint256 tokensIntoLiqudity);

    modifier onlyOperator() {
        require(_operator == msg.sender, "operator: caller is not the operator");
        _;
    }

    modifier antiWhale(address sender, address recipient, uint256 amount) {
        if (maxTransferAmount() > 0) {
            if (
                _excludedFromAntiWhale[sender] == false
                && _excludedFromAntiWhale[recipient] == false
            ) {
                require(amount <= maxTransferAmount(), "PANTHER::antiWhale: Transfer amount exceeds the maxTransferAmount");
            }
        }
        _;
    }

    modifier lockTheSwap {
        _inSwapAndLiquify = true;
        _;
        _inSwapAndLiquify = false;
    }

    modifier transferTaxFree {
        uint16 _transferTaxRate = transferTaxRate;
        transferTaxRate = 0;
        _;
        transferTaxRate = _transferTaxRate;
    }

    /**
     * @notice Constructs the PantherToken contract.
     */
    constructor() public BEP20("Ant King Pad", "AKPAD") {
        _operator = _msgSender();
        emit OperatorTransferred(address(0), _operator);

        _excludedFromAntiWhale[msg.sender] = true;
        _excludedFromAntiWhale[address(0)] = true;
        _excludedFromAntiWhale[address(this)] = true;
        _excludedFromAntiWhale[BURN_ADDRESS] = true;
        _excludedFromAntiWhale[_marketingWalletAddress] = true;
        _mint(owner(), 1000000000 * (10**18));
        // pancakeswap router 
        // updatePantherSwapRouter(_pancakeRouter);

    }

    /// @notice Creates `_amount` token to `_to`. Must only be called by the owner (MasterChef).
    function mint(address _to, uint256 _amount) public onlyOwner {
        _mint(_to, _amount);
    }

    /// @dev overrides transfer function to meet tokenomics of PANTHER
    function _transfer(address sender, address recipient, uint256 amount) internal virtual override antiWhale(sender, recipient, amount) {
        // swap and liquify
        if (
            swapAndLiquifyEnabled == true
            && _inSwapAndLiquify == false
            && address(pantherSwapRouter) != address(0)
            && pantherSwapPair != address(0)
            && sender != pantherSwapPair
            && sender != owner()
        ) {
            swapAndLiquify();
        }

        if (recipient == BURN_ADDRESS || transferTaxRate == 0 || _excludedFromAntiWhale[sender] == true || _excludedFromAntiWhale[recipient] == true) {
            super._transfer(sender, recipient, amount);
        } else {
            // default tax is 5% of every transfer
            uint256 allTaxAmount = amount.mul(transferTaxRate).div(10000);
            uint256 marktingAmount = allTaxAmount.mul(taxRate).div(10000);
            uint256 liquidityAmount = allTaxAmount.sub(marktingAmount);
            require(allTaxAmount == marktingAmount + liquidityAmount, "PANTHER::transfer: Burn value invalid");

            // default 95% of transfer sent to recipient
            uint256 sendAmount = amount.sub(allTaxAmount);
            require(amount == sendAmount + allTaxAmount, "PANTHER::transfer: Tax value invalid");

            super._transfer(sender, _marketingWalletAddress, marktingAmount);
            super._transfer(sender, address(this), liquidityAmount);
            super._transfer(sender, recipient, sendAmount);

            amount = sendAmount;
        }
    }

    function setMarketingWallet(address payable wallet) external onlyOwner{
        _marketingWalletAddress = wallet;
    }

    /// @dev Swap and liquify
    function swapAndLiquify() private lockTheSwap transferTaxFree {
        uint256 contractTokenBalance = balanceOf(address(this));
        uint256 maxTransferAmount = maxTransferAmount();
        contractTokenBalance = contractTokenBalance > maxTransferAmount ? maxTransferAmount : contractTokenBalance;

        if (contractTokenBalance >= minAmountToLiquify) {
            // only min amount to liquify
            uint256 liquifyAmount = minAmountToLiquify;

            // split the liquify amount into halves
            uint256 half = liquifyAmount.div(2);
            uint256 otherHalf = liquifyAmount.sub(half);

            // capture the contract's current ETH balance.
            // this is so that we can capture exactly the amount of ETH that the
            // swap creates, and not make the liquidity event include any ETH that
            // has been manually sent to the contract
            uint256 initialBalance = address(this).balance;

            // swap tokens for ETH
            swapTokensForEth(half);

            // how much ETH did we just swap into?
            uint256 newBalance = address(this).balance.sub(initialBalance);

            // add liquidity
            addLiquidity(otherHalf, newBalance);

            emit SwapAndLiquify(half, newBalance, otherHalf);
        }
    }

    /// @dev Swap tokens for eth
    function swapTokensForEth(uint256 tokenAmount) private {
        // generate the pantherSwap pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = pantherSwapRouter.WETH();

        _approve(address(this), address(pantherSwapRouter), tokenAmount);

        // make the swap
        pantherSwapRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this),
            block.timestamp
        );
    }

    /// @dev Add liquidity
    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {
        // approve token transfer to cover all possible scenarios
        _approve(address(this), address(pantherSwapRouter), tokenAmount);

        // add the liquidity
        pantherSwapRouter.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            operator(),
            block.timestamp
        );
    }

    /**
     * @dev Returns the max transfer amount.
     */
    function maxTransferAmount() public view returns (uint256) {
        return totalSupply().mul(maxTransferAmountRate).div(10000);
    }

    /**
     * @dev Returns the address is excluded from antiWhale or not.
     */
    function isExcludedFromAntiWhale(address _account) public view returns (bool) {
        return _excludedFromAntiWhale[_account];
    }

    // To receive BNB from pantherSwapRouter when swapping
    receive() external payable {}

    /**
     * @dev Update the transfer tax rate.
     * Can only be called by the current operator.
     */
    function updateTransferTaxRate(uint16 _transferTaxRate) public onlyOperator {
        require(_transferTaxRate <= MAXIMUM_TRANSFER_TAX_RATE, "PANTHER::updateTransferTaxRate: Transfer tax rate must not exceed the maximum rate.");
        emit TransferTaxRateUpdated(msg.sender, transferTaxRate, _transferTaxRate);
        transferTaxRate = _transferTaxRate;
    }

    /**
     * @dev Update the burn rate.
     * Can only be called by the current operator.
     */
    function updateTaxRate(uint16 _taxRate) public onlyOperator {
        require(_taxRate <= 100, "PANTHER::updatetaxRate: Burn rate must not exceed the maximum rate.");
        emit TaxRateUpdated(msg.sender, taxRate, _taxRate);
        taxRate = _taxRate;
    }

    /**
     * @dev Update the max transfer amount rate.
     * Can only be called by the current operator.
     */
    function updateMaxTransferAmountRate(uint16 _maxTransferAmountRate) public onlyOperator {
        require(_maxTransferAmountRate <= 10000, "PANTHER::updateMaxTransferAmountRate: Max transfer amount rate must not exceed the maximum rate.");
        emit MaxTransferAmountRateUpdated(msg.sender, maxTransferAmountRate, _maxTransferAmountRate);
        maxTransferAmountRate = _maxTransferAmountRate;
    }

    /**
     * @dev Update the min amount to liquify.
     * Can only be called by the current operator.
     */
    function updateMinAmountToLiquify(uint256 _minAmount) public onlyOperator {
        emit MinAmountToLiquifyUpdated(msg.sender, minAmountToLiquify, _minAmount);
        minAmountToLiquify = _minAmount;
    }

    /**
     * @dev Exclude or include an address from antiWhale.
     * Can only be called by the current operator.
     */
    function setExcludedFromAntiWhale(address _account, bool _excluded) public onlyOperator {
        _excludedFromAntiWhale[_account] = _excluded;
    }

    /**
     * @dev Update the swapAndLiquifyEnabled.
     * Can only be called by the current operator.
     */
    function updateSwapAndLiquifyEnabled(bool _enabled) public onlyOperator {
        emit SwapAndLiquifyEnabledUpdated(msg.sender, _enabled);
        swapAndLiquifyEnabled = _enabled;
    }

    /**
     * @dev Update the swap router.
     * Can only be called by the current operator.
     */
    function updatePantherSwapRouter(address _router) public onlyOperator {
        pantherSwapRouter = IUniswapV2Router02(_router);
        pantherSwapPair = IUniswapV2Factory(pantherSwapRouter.factory()).getPair(address(this), pantherSwapRouter.WETH());
        require(pantherSwapPair != address(0), "PANTHER::updatePantherSwapRouter: Invalid pair address.");
        emit PantherSwapRouterUpdated(msg.sender, address(pantherSwapRouter), pantherSwapPair);
    }

    /**
     * @dev Returns the address of the current operator.
     */
    function operator() public view returns (address) {
        return _operator;
    }

    /**
     * @dev Transfers operator of the contract to a new account (`newOperator`).
     * Can only be called by the current operator.
     */
    function transferOperator(address newOperator) public onlyOperator {
        require(newOperator != address(0), "PANTHER::transferOperator: new operator is the zero address");
        emit OperatorTransferred(_operator, newOperator);
        _operator = newOperator;
    }

    
    function safe32(uint n, string memory errorMessage) internal pure returns (uint32) {
        require(n < 2**32, errorMessage);
        return uint32(n);
    }

    function getChainId() internal pure returns (uint) {
        uint256 chainId;
        assembly { chainId := chainid() }
        return chainId;
    }
}