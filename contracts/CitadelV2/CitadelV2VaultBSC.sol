 // SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "../../libs/BaseRelayRecipient.sol";

interface IRouter {
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    function getAmountsOut(uint amountIn, address[] memory path) external view returns (uint[] memory amounts);
}

interface IChainlink {
    function latestAnswer() external view returns (int256);
}

interface IStrategy {
    function invest(uint amount) external;
    function withdraw(uint sharePerc) external;
    function collectProfitAndUpdateWatermark() external returns (uint);
    function adjustWatermark(uint amount, bool signs) external; 
    function reimburse(uint farmIndex, uint sharePerc) external returns (uint);
    function emergencyWithdraw() external;
    function setProfitFeePerc(uint profitFeePerc) external;
    function watermark() external view returns (uint);
    function getAllPool() external view returns (uint);
    function getL1FeeAverage() external view returns (uint);
}

contract CitadelV2VaultBSC is Initializable, ERC20Upgradeable, OwnableUpgradeable, 
        ReentrancyGuardUpgradeable, PausableUpgradeable, BaseRelayRecipient {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    IERC20Upgradeable constant USDT = IERC20Upgradeable(0x55d398326f99059fF775485246999027B3197955);
    IERC20Upgradeable constant USDC = IERC20Upgradeable(0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d);
    IERC20Upgradeable constant DAI = IERC20Upgradeable(0x1AF3F329e8BE154074D8769D1FFa4eE058B1DBc3);
    IERC20Upgradeable constant WBNB = IERC20Upgradeable(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);

    IRouter constant router = IRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IStrategy public strategy;
    uint[] public percKeepInVault;
    uint public fees;

    uint[] public networkFeeTier2;
    uint public customNetworkFeeTier;
    uint[] public networkFeePerc;
    uint public customNetworkFeePerc;

    // Temporarily variable for LP token distribution only
    address[] addresses;
    mapping(address => uint) public depositAmt; // Amount in USD (18 decimals)
    uint totalDepositAmt;

    address public treasuryWallet;
    address public communityWallet;
    address public strategist;
    address public admin;

    event Deposit(address indexed caller, uint depositAmt);
    event Withdraw(address caller, uint withdrawAmt, address tokenWithdraw, uint sharesBurn);
    event Invest(uint amount);
    event DistributeLPToken(address receiver, uint shareMint);
    event TransferredOutFees(uint fees);
    event Reimburse(uint farmIndex, address token, uint amount);
    event Reinvest(uint amount);
    event SetNetworkFeeTier2(uint[] oldNetworkFeeTier2, uint[] newNetworkFeeTier2);
    event SetCustomNetworkFeeTier(uint indexed oldCustomNetworkFeeTier, uint indexed newCustomNetworkFeeTier);
    event SetNetworkFeePerc(uint[] oldNetworkFeePerc, uint[] newNetworkFeePerc);
    event SetCustomNetworkFeePerc(uint indexed oldCustomNetworkFeePerc, uint indexed newCustomNetworkFeePerc);
    event SetProfitFeePerc(uint profitFeePerc);
    event SetTreasuryWallet(address oldTreasuryWallet, address newTreasuryWallet);
    event SetCommunityWallet(address oldCommunityWallet, address newCommunityWallet);
    event SetStrategistWallet(address oldStrategistWallet, address newStrategistWallet);
    event SetAdminWallet(address oldAdmin, address newAdmin);
    event SetBiconomy(address oldBiconomy, address newBiconomy);
    
    modifier onlyOwnerOrAdmin {
        require(msg.sender == owner() || msg.sender == address(admin), "Only owner or admin");
        _;
    }

    function initialize(
        string calldata name, string calldata ticker,
        address _treasuryWallet, address _communityWallet, address _strategist, address _admin,
        address _biconomy, address _strategy
    ) external initializer {
        __ERC20_init(name, ticker);
        __Ownable_init();

        strategy = IStrategy(_strategy);

        treasuryWallet = _treasuryWallet;
        communityWallet = _communityWallet;
        admin = _admin;
        strategist = _strategist;
        trustedForwarder = _biconomy;

        networkFeeTier2 = [50000*1e18+1, 100000*1e18];
        customNetworkFeeTier = 1000000*1e18;
        networkFeePerc = [100, 75, 50];
        customNetworkFeePerc = 25;

        percKeepInVault = [200, 200, 200]; // USDT, USDC, DAI

        USDT.safeApprove(address(router), type(uint).max);
        USDC.safeApprove(address(router), type(uint).max);
        DAI.safeApprove(address(router), type(uint).max);
        WBNB.safeApprove(address(router), type(uint).max);
        WBNB.safeApprove(address(strategy), type(uint).max);
    }

    function deposit(uint amount, IERC20Upgradeable token) external nonReentrant whenNotPaused {
        require(msg.sender == tx.origin || isTrustedForwarder(msg.sender), "Only EOA or Biconomy");
        require(amount > 0, "Amount must > 0");

        address msgSender = _msgSender();
        uint _pool = getAllPoolInUSD();
        token.safeTransferFrom(msgSender, address(this), amount);

        uint amtDeposit = amount;

        uint _networkFeePerc;
        if (amount < networkFeeTier2[0]) _networkFeePerc = networkFeePerc[0]; // Tier 1
        else if (amount <= networkFeeTier2[1]) _networkFeePerc = networkFeePerc[1]; // Tier 2
        else if (amount < customNetworkFeeTier) _networkFeePerc = networkFeePerc[2]; // Tier 3
        else _networkFeePerc = customNetworkFeePerc; // Custom Tier
        uint fee = amount * _networkFeePerc / 10000;
        fees = fees + fee;
        amount = amount - fee;

        uint l1Fee = amount * strategy.getL1FeeAverage() / 10000;
        amount = amount - l1Fee;

        if (depositAmt[msgSender] == 0) {
            addresses.push(msgSender);
            depositAmt[msgSender] = amount;
        } else depositAmt[msgSender] = depositAmt[msgSender] + amount;
        totalDepositAmt = totalDepositAmt + amount;

        totalSupply() == 0 ? _mint(msgSender, amount) : _mint(msgSender, amount * totalSupply() / _pool);//TODO comment

        emit Deposit(msgSender, amtDeposit);
    }

    function withdraw(uint share, IERC20Upgradeable token) external nonReentrant {
        require(msg.sender == tx.origin, "Only EOA");
        require(share > 0, "Shares must > 0");
        require(share <= balanceOf(msg.sender), "Not enough share to withdraw");

        uint _totalSupply = totalSupply();
        uint withdrawAmt = (getAllPoolInUSD() /* - totalDepositAmt */) * share / _totalSupply;
        _burn(msg.sender, share);

        uint tokenAmtInVault = token.balanceOf(address(this));
        
        if (withdrawAmt <= tokenAmtInVault) {
            strategy.adjustWatermark(withdrawAmt, false);
            token.safeTransfer(msg.sender, withdrawAmt);
        } else {
            if (!paused()) {
                strategy.adjustWatermark(withdrawAmt, false);
                strategy.withdraw(withdrawAmt - tokenAmtInVault);
                withdrawAmt = (router.swapExactTokensForTokens(
                    WBNB.balanceOf(address(this)), 0, getPath(address(WBNB), address(token)), address(this), block.timestamp
                ))[1] + tokenAmtInVault;

                token.safeTransfer(msg.sender, withdrawAmt);
            } else {
                withdrawAmt = (router.swapExactTokensForTokens(
                    WBNB.balanceOf(address(this)) * share / _totalSupply, 0, getPath(address(WBNB), address(token)), msg.sender, block.timestamp
                ))[1];
            }
        }

        emit Withdraw(msg.sender, withdrawAmt, address(token), share);
    }

    function invest() public whenNotPaused {
        require(
            msg.sender == admin ||
            msg.sender == owner() ||
            msg.sender == address(this), "Only authorized caller"
        );

        if (strategy.watermark() > 0) collectProfitAndUpdateWatermark();
        (uint USDTAmt, uint USDCAmt, uint DAIAmt) = transferOutFees();

        (uint WBNBAmt, uint tokenAmtToInvest) = swapTokenToWBNB(USDTAmt, USDCAmt, DAIAmt);

        strategy.invest(WBNBAmt);

        strategy.adjustWatermark(tokenAmtToInvest, true);
        // distributeLPToken();

        emit Invest(WBNBAmt);
    }

    function collectProfitAndUpdateWatermark() public whenNotPaused {
        require(
            msg.sender == address(this) ||
            msg.sender == admin ||
            msg.sender == owner(), "Only authorized caller"
        );
        uint fee = strategy.collectProfitAndUpdateWatermark();
        if (fee > 0) fees = fees + fee;
    }

    function distributeLPToken() private {
        uint pool;
        // uint l1Fee = strategy.getL1FeeAverage();
        if (totalSupply() != 0) pool = getAllPoolInUSD() - totalDepositAmt;
        address[] memory _addresses = addresses;
        for (uint i; i < _addresses.length; i ++) {
            address depositAcc = _addresses[i];
            uint _depositAmt = depositAmt[depositAcc];// - (depositAmt[depositAcc] * l1Fee / 10000);
            uint _totalSupply = totalSupply();
            uint share = _totalSupply == 0 ? _depositAmt : _depositAmt * _totalSupply / pool; //TODO CHECK supply increase with loop, so more shares for same amount
            //TODO check - also `_depositAmt` doesn't include 10% L1 fee, so prints more shares than previous user
            _mint(depositAcc, share);
            pool = pool + _depositAmt;
            depositAmt[depositAcc] = 0;
            emit DistributeLPToken(depositAcc, share);
        }
        delete addresses;
        totalDepositAmt = 0;
    }

    function transferOutFees() public returns (uint USDTAmt, uint USDCAmt, uint DAIAmt) {
        require(
            msg.sender == address(this) ||
            msg.sender == admin ||
            msg.sender == owner(), "Only authorized caller"
        );

        USDTAmt = USDT.balanceOf(address(this));
        USDCAmt = USDC.balanceOf(address(this));
        DAIAmt = DAI.balanceOf(address(this));

        uint _fees = fees;
        if (_fees != 0) {
            IERC20Upgradeable token;
            if (USDTAmt > _fees) {
                token = USDT;
                USDTAmt = USDTAmt - _fees;
            } else if (USDCAmt > _fees) {
                token = USDC;
                USDCAmt = USDCAmt - _fees;
            } else if (DAIAmt > _fees) {
                token = DAI;
                DAIAmt = DAIAmt - _fees;
            } else return (USDTAmt, USDCAmt, DAIAmt);

            uint _fee = _fees * 2 / 5; // 40%
            token.safeTransfer(treasuryWallet, _fee); // 40%
            token.safeTransfer(communityWallet, _fee); // 40%
            token.safeTransfer(strategist, _fees - _fee - _fee); // 20%

            fees = 0;
            emit TransferredOutFees(_fees); // Decimal follow _token
        }
    }

    function swapTokenToWBNB(uint USDTAmt, uint USDCAmt, uint DAIAmt) private returns (uint WBNBAmt, uint tokenAmtToInvest) {
        uint[] memory _percKeepInVault = percKeepInVault;
        uint pool = getAllPoolInUSD();

        uint USDTAmtKeepInVault = calcTokenKeepInVault(_percKeepInVault[0], pool);
        if (USDTAmt > USDTAmtKeepInVault + 1e18) {
            USDTAmt = USDTAmt - USDTAmtKeepInVault;
            WBNBAmt = _swap(address(USDT), address(WBNB), USDTAmt);
            tokenAmtToInvest = USDTAmt;
        }

        uint USDCAmtKeepInVault = calcTokenKeepInVault(_percKeepInVault[1], pool);
        if (USDCAmt > USDCAmtKeepInVault + 1e18) {
            USDCAmt = USDCAmt - USDCAmtKeepInVault;
            uint _WBNBAmt = _swap(address(USDC), address(WBNB), USDCAmt);
            WBNBAmt = WBNBAmt + _WBNBAmt;
            tokenAmtToInvest = tokenAmtToInvest + USDCAmt;
        }

        uint DAIAmtKeepInVault = calcTokenKeepInVault(_percKeepInVault[2], pool);
        if (DAIAmt > DAIAmtKeepInVault + 1e18) {
            DAIAmt = DAIAmt - DAIAmtKeepInVault;
            uint _WBNBAmt = _swap(address(DAI), address(WBNB), DAIAmt);
            WBNBAmt = WBNBAmt + _WBNBAmt;
            tokenAmtToInvest = tokenAmtToInvest + DAIAmt;
        }
    }

    function calcTokenKeepInVault(uint _percKeepInVault, uint pool) private pure returns (uint) {
        return pool * _percKeepInVault / 10000;
    }

    /// @param amount Amount to reimburse (decimal follow token)
    function reimburse(uint farmIndex, address token, uint amount) external onlyOwnerOrAdmin {
        uint WBNBAmt;
        WBNBAmt = (router.getAmountsOut(amount, getPath(token, address(WBNB))))[1];
        WBNBAmt = strategy.reimburse(farmIndex, WBNBAmt);
        _swap(address(WBNB), token, WBNBAmt);

        strategy.adjustWatermark(amount, false);

        emit Reimburse(farmIndex, token, amount);
    }

    function emergencyWithdraw() external onlyOwnerOrAdmin whenNotPaused {
        _pause();
        strategy.emergencyWithdraw();
    }

    function reinvest() external onlyOwnerOrAdmin whenPaused {
        _unpause();

        uint WBNBAmt = WBNB.balanceOf(address(this));
        strategy.invest(WBNBAmt);
        uint BNBPriceInUSD = uint(IChainlink(0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE).latestAnswer());
        require(BNBPriceInUSD > 0, "ChainLink error");
        strategy.adjustWatermark(WBNBAmt * BNBPriceInUSD / 1e8, true);

        emit Reinvest(WBNBAmt);
    }

    function _swap(address from, address to, uint amount) private returns (uint) {
        return (router.swapExactTokensForTokens(
            amount, 0, getPath(from, to), address(this), block.timestamp
        ))[1];
    }

    function setNetworkFeeTier2(uint[] calldata _networkFeeTier2) external onlyOwner {
        require(_networkFeeTier2[0] != 0, "Minimun amount cannot be 0");
        require(_networkFeeTier2[1] > _networkFeeTier2[0], "Maximun amount must > minimun amount");
        /**
         * Network fee has three tier, but it is sufficient to have minimun and maximun amount of tier 2
         * Tier 1: deposit amount < minimun amount of tier 2
         * Tier 2: minimun amount of tier 2 <= deposit amount <= maximun amount of tier 2
         * Tier 3: amount > maximun amount of tier 2
         */
        uint[] memory oldNetworkFeeTier2 = networkFeeTier2;
        networkFeeTier2 = _networkFeeTier2;
        emit SetNetworkFeeTier2(oldNetworkFeeTier2, _networkFeeTier2);
    }

    function setCustomNetworkFeeTier(uint _customNetworkFeeTier) external onlyOwner {
        require(_customNetworkFeeTier > networkFeeTier2[1], "Must > tier 2");
        uint oldCustomNetworkFeeTier = customNetworkFeeTier;
        customNetworkFeeTier = _customNetworkFeeTier;
        emit SetCustomNetworkFeeTier(oldCustomNetworkFeeTier, _customNetworkFeeTier);
    }

    function setNetworkFeePerc(uint[] calldata _networkFeePerc) external onlyOwner {
        require(_networkFeePerc[0] < 3001 && _networkFeePerc[1] < 3001 && _networkFeePerc[2] < 3001,
            "Not allow > 30%");
        /**
         * _networkFeePerc contains an array of 3 elements, representing network fee of tier 1, tier 2 and tier 3
         * For example networkFeePerc is [100, 75, 50],
         * which mean network fee for Tier 1 = 1%, Tier 2 = 0.75% and Tier 3 = 0.5% (Denominator = 10000)
         */
        uint[] memory oldNetworkFeePerc = networkFeePerc;
        networkFeePerc = _networkFeePerc;
        emit SetNetworkFeePerc(oldNetworkFeePerc, _networkFeePerc);
    }

    function setCustomNetworkFeePerc(uint _customNetworkFeePerc) external onlyOwner {
        require(_customNetworkFeePerc < networkFeePerc[2], "Not allow > tier 2");
        uint oldCustomNetworkFeePerc = customNetworkFeePerc;
        customNetworkFeePerc = _customNetworkFeePerc;
        emit SetCustomNetworkFeePerc(oldCustomNetworkFeePerc, _customNetworkFeePerc);
    }

    function setProfitFeePerc(uint profitFeePerc) external onlyOwner {
        require(profitFeePerc < 3001, "Profit fee cannot > 30%");
        strategy.setProfitFeePerc(profitFeePerc);
        emit SetProfitFeePerc(profitFeePerc);
    }

    function setTreasuryWallet(address _treasuryWallet) external onlyOwner {
        address oldTreasuryWallet = treasuryWallet;
        treasuryWallet = _treasuryWallet;
        emit SetTreasuryWallet(oldTreasuryWallet, _treasuryWallet);
    }

    function setCommunityWallet(address _communityWallet) external onlyOwner {
        address oldCommunityWallet = communityWallet;
        communityWallet = _communityWallet;
        emit SetCommunityWallet(oldCommunityWallet, _communityWallet);
    }

    function setStrategist(address _strategist) external {
        require(msg.sender == strategist || msg.sender == owner(), "Only owner or strategist");
        address oldStrategist = strategist;
        strategist = _strategist;
        emit SetStrategistWallet(oldStrategist, _strategist);
    }

    function setAdmin(address _admin) external onlyOwner {
        address oldAdmin = admin;
        admin = _admin;
        emit SetAdminWallet(oldAdmin, _admin);
    }

    function setBiconomy(address _biconomy) external onlyOwner {
        address oldBiconomy = trustedForwarder;
        trustedForwarder = _biconomy;
        emit SetBiconomy(oldBiconomy, _biconomy);
    }

    function _msgSender() internal override(ContextUpgradeable, BaseRelayRecipient) view returns (address) {
        return BaseRelayRecipient._msgSender();
    }
    
    function versionRecipient() external pure override returns (string memory) {
        return "1";
    }

    function getPath(address tokenA, address tokenB) private pure returns (address[] memory path) {
        path = new address[](2);
        path[0] = tokenA;
        path[1] = tokenB;
    }

    function getTotalPendingDeposits() external view returns (uint) {
        return addresses.length;
    }

    function getAvailableInvest() external view returns (uint availableInvest) {
        uint[] memory _percKeepInVault = percKeepInVault;
        uint pool = getAllPoolInUSD();

        uint USDTAmtKeepInVault = calcTokenKeepInVault(_percKeepInVault[0], pool);
        uint USDTAmt = USDT.balanceOf(address(this));
        if (USDTAmt > USDTAmtKeepInVault) availableInvest = USDTAmt - USDTAmtKeepInVault;

        uint USDCAmtKeepInVault = calcTokenKeepInVault(_percKeepInVault[1], pool);
        uint USDCAmt = USDC.balanceOf(address(this));
        if (USDCAmt > USDCAmtKeepInVault) availableInvest += USDCAmt - USDCAmtKeepInVault;

        uint DAIAmtKeepInVault = calcTokenKeepInVault(_percKeepInVault[2], pool);
        uint DAIAmt = DAI.balanceOf(address(this));
        if (DAIAmt > DAIAmtKeepInVault) availableInvest += DAIAmt - DAIAmtKeepInVault;
    }

    function getAllPoolInBNB() external view returns (uint) {
        uint WBNBAmt; // Stablecoins amount keep in vault convert to WBNB

        uint USDTAmt = USDT.balanceOf(address(this));
        if (USDTAmt > 1e18) {
            WBNBAmt = (router.getAmountsOut(USDTAmt, getPath(address(USDT), address(WBNB))))[1];
        }
        uint USDCAmt = USDC.balanceOf(address(this));
        if (USDCAmt > 1e18) {
            uint _WBNBAmt = (router.getAmountsOut(USDCAmt, getPath(address(USDC), address(WBNB))))[1];
            WBNBAmt = WBNBAmt + _WBNBAmt;
        }
        uint DAIAmt = DAI.balanceOf(address(this));
        if (DAIAmt > 1e18) {
            uint _WBNBAmt = (router.getAmountsOut(DAIAmt, getPath(address(DAI), address(WBNB))))[1];
            WBNBAmt = WBNBAmt + _WBNBAmt;
        }
        uint feesInBNB;
        if (fees > 1e18) {
            // Assume fees pay in USDT
            feesInBNB = (router.getAmountsOut(fees, getPath(address(USDT), address(WBNB))))[1];
        }

        if (paused()) return WBNB.balanceOf(address(this)) + WBNBAmt - feesInBNB;
        return strategy.getAllPool() + WBNBAmt - feesInBNB;
    }

    function getAllPoolInUSD() public view returns (uint) {
        // ETHPriceInUSD amount in 8 decimals
        uint BNBPriceInUSD = uint(IChainlink(0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE).latestAnswer()); 
        require(BNBPriceInUSD > 0, "ChainLink error");
        
        uint tokenKeepInVault = USDT.balanceOf(address(this)) + 
            USDC.balanceOf(address(this)) + DAI.balanceOf(address(this));

        if (paused()) return WBNB.balanceOf(address(this)) * BNBPriceInUSD / 1e8 + tokenKeepInVault - fees;
        uint strategyPoolInUSD = strategy.getAllPool() * BNBPriceInUSD / 1e8;
        return strategyPoolInUSD + tokenKeepInVault - fees;
    }

    /// @notice Can be use for calculate both user shares & APR    
    function getPricePerFullShare() external view returns (uint) {
        return getAllPoolInUSD() * 1e18 / totalSupply();
    }
}
