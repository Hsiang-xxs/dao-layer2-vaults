// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface ICurvePool {
    function add_liquidity(uint256[2] memory _amounts, uint256 _amountOutMin) external;
    function remove_liquidity_one_coin(uint256 _amount, int128 _index, uint256 _amountOutMin) external;
    function get_virtual_price() external view returns (uint256);
}

interface IEarnVault {
    function lpToken() external view returns (address);
    function investZap(uint256 _amount) external;
}


interface ISushiRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint[] memory amounts);
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint[] memory amounts);
    function getAmountsOut(uint256 amountIn, address[] memory path) external view returns (uint[] memory amounts);
}

contract CurveHBTCZap is Ownable {
    using SafeERC20 for IERC20;

    ISushiRouter private constant _sushiRouter = ISushiRouter(0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F);
    ICurvePool public curvePool;

    IERC20 private constant _WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 private constant _HBTC = IERC20(0x0316EB71485b0Ab14103307bf65a021042c6d380);
    IERC20 private constant _WBTC = IERC20(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);

    mapping(address => bool) public isWhitelistedVault;

    event Deposit(address indexed vault, uint256 amount, address indexed coin, uint256 lptokenBal, uint256 daoERNBal, bool stake);
    event Withdraw(address indexed vault, uint256 shares, address indexed coin, uint256 lptokenBal, uint256 coinAmount);
    event SwapFees(uint256 amount, uint256 coinAmount, address indexed coin);
    event Compound(uint256 amount, address indexed vault, uint256 lpTokenBal);
    event AddLiquidity(uint256 amount, address indexed vault, address indexed best, uint256 lpTokenBal);
    event EmergencyWithdraw(uint256 amount, address indexed vault, uint256 lpTokenBal);
    event AddPool(address indexed vault, address indexed curvePool);
    
    event SetBiconomy(address indexed biconomy);

    modifier onlyEOAOrBiconomy {
        require(msg.sender == tx.origin, "Only EOA or Biconomy");
        _;
    }

    constructor() {
        _WETH.safeApprove(address(_sushiRouter), type(uint).max);
    }

    /// @notice Function to swap fees from vault contract (and transfer back to vault contract)
    /// @param _amount Amount of LP token to be swapped (18 decimals)
    /// @return Amount and address of coin to receive (amount follow decimal of coin)
    function swapFees(uint256 _amount) external returns (uint256, address) {
        require(address(curvePool) != address(0), "Only authorized vault");
        IERC20(IEarnVault(msg.sender).lpToken()).safeTransferFrom(msg.sender, address(this), _amount);
        curvePool.remove_liquidity_one_coin(_amount, 1, 0);
        uint256 _coinAmount = _WBTC.balanceOf(address(this));
        _WBTC.safeTransfer(msg.sender, _coinAmount);
        emit SwapFees(_amount, _coinAmount, address(_WBTC));
        return (_coinAmount, address(_WBTC));
    }

    /// @notice Function to swap WETH from strategy contract (and invest into strategy contract)
    /// @param _amount Amount to compound in WETH
    /// @return _lpTokenBal LP token amount to invest after add liquidity to Curve pool (18 decimals)
    function compound(uint256 _amount) external returns (uint256 _lpTokenBal) {
        require(isWhitelistedVault[msg.sender], "Only authorized vault");
        _lpTokenBal = _addLiquidity(_amount, msg.sender);
        IEarnVault(msg.sender).investZap(_lpTokenBal);
        emit Compound(_amount, msg.sender, _lpTokenBal);
    }

    /// @notice Function to swap WETH and add liquidity into Curve pool
    /// @param _amount Amount of WETH to swap and add into Curve pool
    /// @param _vault Address of vault contract to determine pool
    /// @return _lpTokenBal LP token amount received after add liquidity into Curve pool (18 decimals)
    function _addLiquidity(uint256 _amount, address _vault) private returns (uint256 _lpTokenBal) {
        _WETH.safeTransferFrom(_vault, address(this), _amount);
        address[] memory _path = new address[](2);
        _path[0] = address(_WETH);
        _path[1] = address(_WBTC);
        uint256[] memory _amountsOut = _sushiRouter.swapExactTokensForTokens(_amount, 0, _path, address(this), block.timestamp);
        uint256[2] memory _amounts = [0, _amountsOut[1]];
        curvePool.add_liquidity(_amounts, 0);
        _lpTokenBal = IERC20(IEarnVault(_vault).lpToken()).balanceOf(address(this));
        emit AddLiquidity(_amount, _vault, address(_WBTC), _lpTokenBal);
    }

    /// @notice Same function as compound() but transfer received LP token to vault instead of strategy contract
    /// @param _amount Amount to emergency withdraw in WETH
    /// @param _vault Address of vault contract
    function emergencyWithdraw(uint256 _amount, address _vault) external {
        require(isWhitelistedVault[msg.sender], "Only authorized vault");

        uint256 _lpTokenBal = _addLiquidity(_amount, _vault);
        IERC20(IEarnVault(_vault).lpToken()).safeTransfer(_vault, _lpTokenBal);
        emit EmergencyWithdraw(_amount, _vault, _lpTokenBal);
    }

    /// @notice Function to add new Curve pool (limit to Curve HBTC pool only)
    /// @param vault_ Address of corresponding vault contract
    /// @param curvePool_ Address of Curve metapool contract
    function addPool(address vault_, address curvePool_) external onlyOwner {
        IEarnVault _vault = IEarnVault(vault_);
        IERC20 _lpToken = IERC20(_vault.lpToken());

        isWhitelistedVault[vault_] = true;
        
        curvePool = ICurvePool(curvePool_);

        _lpToken.safeApprove(vault_, type(uint).max);
        _HBTC.safeApprove(curvePool_, type(uint).max);
        _WBTC.safeApprove(curvePool_, type(uint).max);

        emit AddPool(vault_, curvePool_);
    }

    function setWhitelistVault(address _vault, bool _status) external onlyOwner {
        isWhitelistedVault[_vault] = _status;
    }

    /// @notice Function to get LP token price
    /// @return LP token price of corresponding Curve pool (18 decimals)
    function getVirtualPrice() external view returns (uint256) {
        return curvePool.get_virtual_price();
    }

    /// @notice Function to check token availability to depositZap(). _tokenOut = WBTC
    /// @param _amount Amount to be swapped (decimals follow _tokenIn)
    /// @param _tokenIn Address to be swapped
    /// @return Amount out in BTC. Token not available if return 0.
    function checkTokenSwapAvailability(uint256 _amount, address _tokenIn) external view returns (uint256) {
        address[] memory _path = new address[](3);
        _path[0] = _tokenIn;
        _path[1] = address(_WETH);
        _path[2] = address(_WBTC);
        try _sushiRouter.getAmountsOut(_amount, _path) returns (uint256[] memory _amountsOut){
            return _amountsOut[2];
        } catch {
            return 0;
        }
    }
}