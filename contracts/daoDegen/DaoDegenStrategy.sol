// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

interface IRouter {
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB);

    function getAmountsOut(uint amountIn, address[] memory path) external view returns (uint[] memory amounts);
}


interface IDaoL1Vault is IERC20Upgradeable {
    function deposit(uint amount) external;
    function withdraw(uint share) external;
    function getAllPoolInUSD() external view returns (uint);
    function getAllPoolInBNB() external view returns (uint);
    function depositFee() external view returns (uint);
    function isWhitelisted(address) external view returns (bool);
}

interface IChainlink {
    function latestAnswer() external view returns (int256);
}

contract DaoDegenStrategy is Initializable, OwnableUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    IERC20Upgradeable public constant CAKE  = IERC20Upgradeable(0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82);
    IERC20Upgradeable public constant WBNB = IERC20Upgradeable(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IERC20Upgradeable public constant BUSD = IERC20Upgradeable(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);

    IERC20Upgradeable public constant ALPACA = IERC20Upgradeable(0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c);
    IERC20Upgradeable public constant XVS = IERC20Upgradeable(0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c);
    IERC20Upgradeable public constant BELT = IERC20Upgradeable(0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c);
    IERC20Upgradeable public constant USDC = IERC20Upgradeable(0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c);
    IERC20Upgradeable public constant CHESS = IERC20Upgradeable(0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c);

    IERC20Upgradeable public constant BUSDALPACA = IERC20Upgradeable(0x7752e1FA9F3a2e860856458517008558DEb989e3);
    IERC20Upgradeable public constant BNBXVS = IERC20Upgradeable(0x7EB5D86FD78f3852a3e0e064f2842d45a3dB6EA2);
    IERC20Upgradeable public constant BNBBELT = IERC20Upgradeable(0xF3Bc6FC080ffCC30d93dF48BFA2aA14b869554bb);
    IERC20Upgradeable public constant CHESSUSDC = IERC20Upgradeable(0x1472976E0B97F5B2fC93f1FFF14e2b5C4447b64F);

    IRouter public constant PnckRouter = IRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    IDaoL1Vault public BUSDALPACAVault;
    IDaoL1Vault public BNBXVSVault;
    IDaoL1Vault public BNBBELTVault;
    IDaoL1Vault public CHESSUSDCVault;
    

    uint constant BUSDALPACATargetPerc = 2500;
    uint constant BNBXVSTargetPerc = 2500;
    uint constant BNBBELTTargetPerc = 2500;
    uint constant CHESSUSDCTargetPerc = 2500;

    address public vault;
    uint public watermark; // In USD (18 decimals)
    uint public profitFeePerc;

    event TargetComposition (uint BUSDALPACATargetPool, uint BNBXVSTargetPool, uint BNBBELTPool, uint CHESSUSDCTargetPool);
    event CurrentComposition (uint BUSDALPACATargetPool, uint BNBXVSTargetPool, uint BNBBELTCurrentPool, uint CHESSUSDCCurrentPool);
    event InvestBUSDALPACA(uint BNBAmt, uint BUSDALPACAAmt);
    event InvestBNBXVS(uint BNBAmt, uint BNBXVSAmt);
    event InvestBNBBELT(uint BNBAmt, uint BNBBELTAmt);
    event InvestCHESSUSDC(uint BNBAmt, uint CHESSUSDCAmt);
    event Withdraw(uint amount, uint BNBAmt);
    event WithdrawBUSDALPACA(uint lpTokenAmt, uint BNBAmt);
    event WithdrawBNBXVS(uint lpTokenAmt, uint BNBAmt);
    event WithdrawBNBBELT(uint lpTokenAmt, uint BNBAmt);
    event WithdrawCHESSUSDC(uint lpTokenAmt, uint BNBAmt);
    event CollectProfitAndUpdateWatermark(uint currentWatermark, uint lastWatermark, uint fee);
    event AdjustWatermark(uint currentWatermark, uint lastWatermark);
    event Reimburse(uint BNBAmt);
    event EmergencyWithdraw(uint BNBAmt);

    modifier onlyVault {
        require(msg.sender == vault, "Only vault");
        _;
    }

    function initialize(IDaoL1Vault _BUSDALPACAVault, IDaoL1Vault _BNBXVSVault, IDaoL1Vault _BNBBELTVault, 
        IDaoL1Vault _CHESSUSDCVault) external initializer {
        __Ownable_init();

        BUSDALPACAVault = _BUSDALPACAVault;
        BNBXVSVault = _BNBXVSVault;
        BNBBELTVault = _BNBBELTVault;
        CHESSUSDCVault = _CHESSUSDCVault;

        profitFeePerc = 2000;

        CAKE.safeApprove(address(PnckRouter), type(uint).max);
        WBNB.safeApprove(address(PnckRouter), type(uint).max);
        ALPACA.safeApprove(address(PnckRouter), type(uint).max);
        BUSD.safeApprove(address(PnckRouter), type(uint).max);
        CHESS.safeApprove(address(PnckRouter), type(uint).max);
        USDC.safeApprove(address(PnckRouter), type(uint).max);
        XVS.safeApprove(address(PnckRouter), type(uint).max);

        BUSDALPACA.safeApprove(address(BUSDALPACAVault), type(uint).max);
        BNBXVS.safeApprove(address(BNBXVSVault), type(uint).max);
        BNBBELT.safeApprove(address(BNBBELTVault), type(uint).max);
        CHESSUSDC.safeApprove(address(CHESSUSDCVault), type(uint).max);

        BUSDALPACA.safeApprove(address(PnckRouter), type(uint).max);
        BNBXVS.safeApprove(address(PnckRouter), type(uint).max);
        BNBBELT.safeApprove(address(PnckRouter), type(uint).max);
        CHESSUSDC.safeApprove(address(PnckRouter), type(uint).max);

    }

    function invest(uint WBNBAmt) external onlyVault {
        WBNB.safeTransferFrom(vault, address(this), WBNBAmt);
        WBNBAmt = WBNB.balanceOf(address(this));
        
        uint[] memory pools = getEachPool();
        uint pool = pools[0] + pools[1] + pools[2] + pools[3] + WBNBAmt;
        uint BUSDALPACATargetPool = pool * 2500 / 10000; // 25%
        uint BNBXVSTargetPool = BUSDALPACATargetPool; // 25%
        uint BNBBELTTargetPool = BUSDALPACATargetPool; // 25%
        uint CHESSUSDCTargetPool = BUSDALPACATargetPool; // 25%

        // Rebalancing invest
        if (
            BUSDALPACATargetPool > pools[0] &&
            BNBXVSTargetPool > pools[1] &&
            BNBBELTTargetPool > pools[2] &&
            CHESSUSDCTargetPool > pools[3]
        ) {
            _investBUSDALPACA(BUSDALPACATargetPool - pools[0]);
            _investBNBXVS((BNBXVSTargetPool - pools[1]));
            _investBNBBELT((BNBBELTTargetPool - pools[2]));
            _investCHESSUSDC((CHESSUSDCTargetPool - pools[3]));
        } else {
            uint furthest;
            uint farmIndex;
            uint diff;

            if (BUSDALPACATargetPool > pools[0]) {
                diff = BUSDALPACATargetPool - pools[0];
                furthest = diff;
                farmIndex = 0;
            }
            if (BNBXVSTargetPool > pools[1]) {
                diff = BNBXVSTargetPool - pools[1];
                if (diff > furthest) {
                    furthest = diff;
                    farmIndex = 1;
                }
            }
            if (BNBBELTTargetPool > pools[2]) {
                diff = BNBBELTTargetPool - pools[2];
                if (diff > furthest) {
                    furthest = diff;
                    farmIndex = 2;
                }
            }
            if (CHESSUSDCTargetPool > pools[3]) {
                diff = CHESSUSDCTargetPool - pools[3];
                if (diff > furthest) {
                    furthest = diff;
                    farmIndex = 3;
                }
            }

            if (farmIndex == 0) _investBUSDALPACA(WBNBAmt);
            else if (farmIndex == 1) _investBNBXVS(WBNBAmt);
            else if (farmIndex == 2) _investBNBBELT(WBNBAmt);
            else _investCHESSUSDC(WBNBAmt);
        }

        emit TargetComposition(BUSDALPACATargetPool, BNBXVSTargetPool, BNBBELTTargetPool, CHESSUSDCTargetPool);
        emit CurrentComposition(pools[0], pools[1], pools[2], pools[3]);
    }


    function _investBUSDALPACA(uint _wbnbAmt) private {
        uint _amt = _wbnbAmt/2;

        _swap(address(WBNB), address(BUSD), _amt);
        _swap(address(WBNB), address(ALPACA), _amt);

        uint _busdAmt = BUSD.balanceOf(address(this));
        uint _alpacaAmt = ALPACA.balanceOf(address(this));
        
        uint lpTokens = _addLiquidity(address(BUSD), address(ALPACA), _busdAmt, _alpacaAmt);

        BUSDALPACAVault.deposit(lpTokens);

        emit InvestBUSDALPACA(_wbnbAmt, lpTokens);
    }

    function _investBNBXVS(uint _wbnbAmt) private {
        uint _amt = _wbnbAmt / 2 ;
        _swap(address(WBNB), address(XVS), _amt);

        uint _XVSBAmt = XVS.balanceOf(address(this));
        uint lpTokens = _addLiquidity(address(WBNB), address(XVS), _amt, _XVSBAmt);

        BNBXVSVault.deposit(lpTokens);

        emit InvestBNBXVS(_wbnbAmt, lpTokens);
    }

    function _investBNBBELT(uint _wbnbAmt) private {
        uint _amt = _wbnbAmt / 2 ;
        _swap(address(WBNB), address(BELT), _amt);

        uint _BELTAmt = BELT.balanceOf(address(this));
        uint lpTokens = _addLiquidity(address(WBNB), address(BELT), _amt, _BELTAmt);

        BNBBELTVault.deposit(lpTokens);

        emit InvestBNBBELT(_wbnbAmt, lpTokens);
    }

    function _investCHESSUSDC(uint _wbnbAmt) private {
        uint _amt = _wbnbAmt / 2 ;

        _swap(address(WBNB), address(CHESS), _amt);
        _swap(address(WBNB), address(USDC), _amt);

        uint _CHESSAmt = CHESS.balanceOf(address(this));
        uint _USDCAmt = BUSD.balanceOf(address(this));

        uint lpTokens = _addLiquidity(address(CHESS), address(USDC), _CHESSAmt, _USDCAmt);

        CHESSUSDCVault.deposit(lpTokens);

        emit InvestCHESSUSDC(_wbnbAmt, lpTokens);
    }

    function withdraw(uint amount) external onlyVault returns (uint WBNBAmt) {
        uint sharePerc = amount * 1e18 / getAllPoolInUSD();
        
        uint WBNBAmtBefore = WBNB.balanceOf(address(this));
        _withdrawBUSDALPACA(sharePerc);
        _withdrawBNBXVS(sharePerc);
        _withdrawBNBBELT(sharePerc);
        _withdrawCHESSUSDC(sharePerc);
        WBNBAmt = WBNB.balanceOf(address(this)) - WBNBAmtBefore;
        WBNB.safeTransfer(vault, WBNBAmt);

        emit Withdraw(amount, WBNBAmt);
    }

    function _withdrawBUSDALPACA(uint _sharePerc) private {
        BUSDALPACAVault.withdraw(BUSDALPACAVault.balanceOf(address(this)) * _sharePerc / 1e18 );

        uint _amt = BUSDALPACA.balanceOf(address(this));

        (uint _amtBUSD, uint _amtALPACA) = _removeLiquidity(address(BUSD), address(ALPACA), _amt);

        uint _wBNBAmt = _swap(address(BUSD), address(WBNB), _amtBUSD);
        _wBNBAmt += _swap(address(ALPACA), address(WBNB), _amtALPACA);

        emit WithdrawBUSDALPACA(_amt, _wBNBAmt);
    }


    function _withdrawBNBXVS(uint _sharePerc) private {
        BNBXVSVault.withdraw(BNBXVSVault.balanceOf(address(this)) * _sharePerc / 1e18 );
        uint _amt = BNBXVS.balanceOf(address(this));

        (uint _amtXVS, uint _amtBNB) = _removeLiquidity(address(XVS), address(WBNB), _amt);

        _amtBNB += _swap(address(XVS), address(WBNB), _amtXVS);

        emit WithdrawBNBXVS(_amt, _amtBNB);
    }

    function _withdrawBNBBELT(uint _sharePerc) private {
        BNBBELTVault.withdraw(BNBBELTVault.balanceOf(address(this)) * _sharePerc / 1e18 );
        uint _amt = BNBBELT.balanceOf(address(this));
        (uint _amtBELT, uint _amtBNB) = _removeLiquidity(address(BELT), address(WBNB), _amt);

        _amtBNB += _swap(address(BELT), address(WBNB), _amtBELT);

        emit WithdrawBNBBELT(_amt, _amtBNB);
    }

    // function _withdrawCHESSUSDC(uint _amount, uint _allPool) private {
    function _withdrawCHESSUSDC(uint _sharePerc) private {
        CHESSUSDCVault.withdraw(CHESSUSDCVault.balanceOf(address(this)) * _sharePerc / 1e18);
        uint _amt = CHESSUSDC.balanceOf(address(this));

        (uint _amtCHESS, uint _amtUSDC) = _removeLiquidity(address(CHESS), address(USDC), _amt);

        uint _wBNBAmt = _swap(address(CHESS), address(WBNB), _amtCHESS);
        _wBNBAmt += _swap(address(USDC), address(WBNB), _amtUSDC);

        emit WithdrawCHESSUSDC(_amt, _wBNBAmt);
    }

    function collectProfitAndUpdateWatermark() public onlyVault returns (uint fee) {
        uint currentWatermark = getAllPoolInUSD();
        
        uint lastWatermark = watermark;
        if (currentWatermark > lastWatermark) {
            uint profit = currentWatermark - lastWatermark;
            fee = profit * profitFeePerc / 10000;
            watermark = currentWatermark - fee;
        }
        emit CollectProfitAndUpdateWatermark(currentWatermark, lastWatermark, fee);
    }

    /// @param signs True for positive, false for negative
    function adjustWatermark(uint amount, bool signs) external onlyVault {
        
        uint lastWatermark = watermark;
        watermark = signs == true ? watermark + amount : watermark - amount;
        emit AdjustWatermark(watermark, lastWatermark);
    }

    function _swap(address _tokenA, address _tokenB, uint _amt) private returns (uint) {
        address[] memory path = new address[](2);

        path[0] = _tokenA;
        path[1] = _tokenB;


        return (PnckRouter.swapExactTokensForTokens(_amt , 0, path, address(this), block.timestamp))[1];
    }

    function _addLiquidity(address _tokenA, address _tokenB, uint _amtA, uint _amtB) private returns (uint liquidity) {
        (,,liquidity) = PnckRouter.addLiquidity(_tokenA, _tokenB, _amtA, _amtB, 0, 0, address(this), block.timestamp);
    }

    function _removeLiquidity(address _tokenA, address _tokenB, uint _amt) private returns (uint _amtA, uint _amtB) {
        (_amtA, _amtB) = PnckRouter.removeLiquidity(_tokenA, _tokenB, _amt, 0, 0, address(this), block.timestamp);
    }

    /// @param amount Amount to reimburse to vault contract in ETH
    function reimburse(uint farmIndex, uint amount) external onlyVault returns (uint WBNBAmt) {
        if (farmIndex == 0) _withdrawBUSDALPACA(amount * 1e18 / getBUSDALPACAPool()); 
        else if (farmIndex == 1) _withdrawBNBXVS(amount * 1e18 / getBNBXVSPool());
        else if (farmIndex == 2) _withdrawBNBBELT(amount * 1e18 / getBNBBELTPool());
        else if (farmIndex == 3) _withdrawCHESSUSDC(amount * 1e18 / getCHESSUSDCPool());
        WBNBAmt = WBNB.balanceOf(address(this));
        WBNB.safeTransfer(vault, WBNBAmt);
        emit Reimburse(WBNBAmt);
    }

    function setVault(address _vault) external onlyOwner {
        require(vault == address(0), "Vault set");
        vault = _vault;
    }

    function setProfitFeePerc(uint _profitFeePerc) external onlyVault {
        profitFeePerc = _profitFeePerc;
    }

    function emergencyWithdraw() external onlyVault {
        // 1e18 == 100% of share
        _withdrawBUSDALPACA(1e18); 
        _withdrawBNBXVS(1e18);
        _withdrawBNBBELT(1e18);
        _withdrawCHESSUSDC(1e18);
        uint WBNBAmt = WBNB.balanceOf(address(this));
        WBNB.safeTransfer(vault, WBNBAmt);
        watermark = 0;
        emit EmergencyWithdraw(WBNBAmt);
    }

    function getBUSDALPACAPool() private view  returns (uint) {
        return BUSDALPACAVault.getAllPoolInBNB();
    }

    function getBNBXVSPool() private view returns (uint) {
        return BNBXVSVault.getAllPoolInBNB();
    }

    function getBNBBELTPool() private view returns (uint) {
        return BNBBELTVault.getAllPoolInBNB();
    }

    function getCHESSUSDCPool() private view returns (uint) {
        return CHESSUSDCVault.getAllPoolInBNB();
    }

    function getEachPool() private view returns (uint[] memory pools) {
        pools = new uint[](4);
        pools[0] = getBUSDALPACAPool();
        pools[1] = getBNBXVSPool();
        pools[2] = getBNBBELTPool();
        pools[3] = getCHESSUSDCPool();
    }

    function getAllPool() public view returns (uint) {
        uint[] memory pools = getEachPool();
        return pools[0] + pools[1] + pools[2] + pools[3];
    }

    function getAllPoolInUSD() public view returns (uint) {
        uint BNBPriceInUSD = uint(IChainlink(0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE).latestAnswer()); // 8 decimals
        require(BNBPriceInUSD > 0, "ChainLink error");
        return getAllPool() * BNBPriceInUSD / 1e8;
    }

    function getCurrentCompositionPerc() external view returns (uint[] memory percentages) {
        uint[] memory pools = getEachPool();
        uint allPool = pools[0] + pools[1] + pools[2] + pools[3];
        percentages = new uint[](4);
        percentages[0] = pools[0] * 10000 / allPool;
        percentages[1] = pools[1] * 10000 / allPool;
        percentages[2] = pools[2] * 10000 / allPool;
        percentages[3] = pools[3] * 10000 / allPool;
    }

    function getL1FeeAverage() external view returns (uint l1Fee) {
        uint denominator;
        if(BUSDALPACAVault.isWhitelisted(address(this)) == false) {
            l1Fee += BUSDALPACAVault.depositFee();

            denominator++;
        }

        if(BNBXVSVault.isWhitelisted(address(this)) == false) {
            l1Fee += BNBXVSVault.depositFee();
            denominator++;
        }

        if(BNBBELTVault.isWhitelisted(address(this)) == false) {
            l1Fee += BNBBELTVault.depositFee();
            denominator++;
        }

        if(CHESSUSDCVault.isWhitelisted(address(this)) == false) {
            l1Fee += CHESSUSDCVault.depositFee();
            denominator++;
        }

        l1Fee = l1Fee / denominator; //average
    }

}
