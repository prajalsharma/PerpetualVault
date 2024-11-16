pragma solidity 0.8.21;

import "../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import "../PriceFeed/ChainLinkPriceFeed.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../Oracle/AggregatorV3Contract.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "forge-std/console.sol";

contract PerpetualVault is ERC4626, Ownable {
    using SafeERC20 for ERC20;

    uint8 public constant MAX_LEVERAGE = 20;
    uint8 public constant GAS_STIPEND = 5;
    uint8 public constant MIN_POSITION_SIZE = 100;
    uint16 public constant POSITION_OPENING_FEE = 20;
    uint8 public constant POSITION_SIZE_CHANGE_BPS = 10;
    uint8 public POSITION_COLLATERAL_CHANGE_BPS = 10;
    uint256 public MAX_ALLOWED_BPS = 8_000;
    uint256 public TOTAL_BPS = 10_000;
    uint256 constant borrowingPerSecond = 315_360_000;
    ERC20 public wBTCToken;
    ERC20 public USDCToken;
    ChainLinkPriceFeed priceFeed;
    uint256 initialBTCInUSDLong;
    uint256 initialBTCInUSDShort;
    uint256 btcSizeOpenedLong;
    uint256 btcSizeOpenedShort;

    struct Position {
        address positionOwner;
        uint256 collateralInUSD;
        bool isLong;
        uint256 creationSizeInUSD;
        bytes32 positionID;
        uint256 size;
        uint256 creationTime;
    }

    mapping(bytes32 => Position) private openPositons;

    error MaxLeverageExcedded();
    error LowCollateral();
    error LowPositionSize();
    error NotThePositionOwner();
    error PositionDoesNotExist();
    error LowPositionCollateral();
    error PositionHealthy();
    error CannotChangeCollateral();
    error CannotChangeSize();
    error TestRevert(uint256);
    error NotEnoughLiquidity();
    error RedeemNotSupported();

    constructor(
        address LPTokenAddress,
        address BTCTokenAddress,
        string memory name,
        string memory symbol,
        address owner
    ) ERC4626(IERC20(LPTokenAddress)) ERC20(name, symbol) Ownable(owner) {
        wBTCToken = ERC20(BTCTokenAddress);
        USDCToken = ERC20(LPTokenAddress);
        priceFeed = new ChainLinkPriceFeed(address(this));
        priceFeed.addToken(
            "USDC",
            address(
                new AggregatorV3Contract(
                    msg.sender, USDCToken.decimals(), int256(1 * (10 ** USDCToken.decimals())), "Oracle"
                )
            ),
            address(
                new AggregatorV3Contract(
                    msg.sender, USDCToken.decimals(), int256(1 * (10 ** USDCToken.decimals())), "Oracle"
                )
            ),
            1,
            USDCToken.decimals()
        );
        priceFeed.addToken(
            "WBTC",
            address(
                new AggregatorV3Contract(
                    msg.sender, wBTCToken.decimals(), int256(100 * (10 ** wBTCToken.decimals())), "Oracle"
                )
            ),
            address(
                new AggregatorV3Contract(
                    msg.sender, wBTCToken.decimals(), int256(100 * (10 ** wBTCToken.decimals())), "Oracle"
                )
            ),
            int256(100 * (10 ** wBTCToken.decimals())),
            wBTCToken.decimals()
        );
    }

    modifier onlyPositionOwner(bytes32 positionID) {
        if (openPositons[positionID].positionOwner != msg.sender) {
            revert NotThePositionOwner();
        }
        _;
    }

    function getBTCAddress() public view returns (IERC20) {
        return wBTCToken;
    }

    function getUSDCAddress() public view returns (IERC20) {
        return USDCToken;
    }

    function totalAssets() public view override(ERC4626) returns (uint256) {
        int256 pnl = getSystemPNL();
        if (pnl <= 0) {
            return super.totalAssets() - _absoluteValue(pnl);
        }
        return super.totalAssets() + uint256(pnl);
    }

    function withdraw(uint256 assets, address reciever, address owner) public override(ERC4626) returns (uint256) {
        uint256 liquidityUsedIdle = _getUsableBalance();
        if (liquidityUsedIdle < assets) {
            revert NotEnoughLiquidity();
        }
        uint256 shares = super.withdraw(assets, reciever, owner);
        return shares;
    }

    function redeem(uint256, address, address) public pure override(ERC4626) returns (uint256) {
        revert RedeemNotSupported();
    }

    function openPosition(uint256 collateralInUSD, uint256 sizeInUSD, bool isLong) external returns (bytes32) {
        if (collateralInUSD == 0) {
            revert LowCollateral();
        }
        if (sizeInUSD < MIN_POSITION_SIZE) {
            revert LowPositionSize();
        }
        if (sizeInUSD / collateralInUSD > MAX_LEVERAGE) {
            revert MaxLeverageExcedded();
        }

        bytes32 positionHash = _getPositionHash(msg.sender, collateralInUSD, sizeInUSD, isLong);

        USDCToken.safeTransferFrom(
            msg.sender,
            address(this),
            (
                (
                    (collateralInUSD + _calculatePositionOpeningFee(sizeInUSD)) * (10 ** USDCToken.decimals())
                        + _getGasStipend()
                ) * (10 ** priceFeed.decimals("USDC"))
            ) / _getUSDCPrice()
        );
        uint256 btcSize =
            (sizeInUSD * (10 ** priceFeed.decimals("WBTC")) * (10 ** wBTCToken.decimals())) / _getBTCPrice();
        openPositons[positionHash] =
            Position(msg.sender, collateralInUSD, isLong, sizeInUSD, positionHash, btcSize, block.timestamp);
        if (isLong) {
            initialBTCInUSDLong += sizeInUSD;
            btcSizeOpenedLong += btcSize;
        } else {
            initialBTCInUSDShort += sizeInUSD;
            btcSizeOpenedShort += btcSize;
        }
        return positionHash;
    }

    function _calculatePositionOpeningFee(uint256 positionSize) internal view returns (uint256) {
        return (positionSize * POSITION_OPENING_FEE) / TOTAL_BPS;
    }

    function calculatePositionSizeChangeFee(uint256 positionSizeChange) internal view returns (uint256) {
        return (positionSizeChange * POSITION_SIZE_CHANGE_BPS) / TOTAL_BPS;
    }

    function calculatePositionCollateralChangeFee(uint256 positionCollateralChange) internal view returns (uint256) {
        return (positionCollateralChange * POSITION_COLLATERAL_CHANGE_BPS) / TOTAL_BPS;
    }

    function increasePositionSize(bytes32 positionID, uint256 sizeChangeInUSD) external onlyPositionOwner(positionID) {
        Position storage position = _getPosition(positionID);
        if (!_canChangeSize(positionID, sizeChangeInUSD, true)) {
            revert CannotChangeSize();
        }

        position.creationSizeInUSD = position.creationSizeInUSD + sizeChangeInUSD;
        uint256 btcSize =
            (sizeChangeInUSD * (10 ** priceFeed.decimals("WBTC")) * (10 ** wBTCToken.decimals())) / _getBTCPrice();
        position.size = position.size + btcSize;
        if (position.isLong) {
            initialBTCInUSDLong += sizeChangeInUSD;
            btcSizeOpenedLong += btcSize;
        } else {
            initialBTCInUSDShort += sizeChangeInUSD;
            btcSizeOpenedShort += btcSize;
        }

        uint256 feeOnSizeChange = (
            calculatePositionSizeChangeFee(sizeChangeInUSD) * (10 ** priceFeed.decimals("USDC"))
                * (10 ** USDCToken.decimals())
        ) / _getUSDCPrice();
        USDCToken.safeTransferFrom(msg.sender, address(this), feeOnSizeChange);
    }

    function decreasePositionSize(bytes32 positionID, uint256 sizeChangeInUSD) external onlyPositionOwner(positionID) {
        Position storage position = _getPosition(positionID);
        if (!_canChangeSize(positionID, sizeChangeInUSD, false)) {
            revert CannotChangeSize();
        }

        position.size = position.size - sizeChangeInUSD;

        uint256 btcSize = (sizeChangeInUSD * (10 ** priceFeed.decimals("WBTC")) * (10 ** wBTCToken.decimals()));
        if (position.isLong) {
            initialBTCInUSDLong -= sizeChangeInUSD;
            btcSizeOpenedLong -= btcSize;
        } else {
            initialBTCInUSDShort -= sizeChangeInUSD;
            btcSizeOpenedShort -= btcSize;
        }
        uint256 feeOnSizeChange = (
            calculatePositionSizeChangeFee(sizeChangeInUSD) * (10 ** priceFeed.decimals("USDC"))
                * (10 ** USDCToken.decimals())
        ) / _getUSDCPrice();
        USDCToken.safeTransferFrom(msg.sender, address(this), feeOnSizeChange);
    }

    function increasePositionCollateral(bytes32 positionID, uint256 collateralChange)
        external
        onlyPositionOwner(positionID)
    {
        Position storage position = _getPosition(positionID);
        if (!_canChangeCollateral(positionID, collateralChange, true)) {
            revert CannotChangeCollateral();
        }
        position.collateralInUSD =
            position.collateralInUSD + (collateralChange * _getUSDCPrice()) / (10 ** priceFeed.decimals("USDC"));
        uint256 feeOnCollateralChange = (
            calculatePositionCollateralChangeFee(collateralChange) * (10 ** priceFeed.decimals("USDC"))
                * (10 ** USDCToken.decimals())
        ) / _getUSDCPrice();
        USDCToken.safeTransferFrom(msg.sender, address(this), feeOnCollateralChange);
    }

    function decreasePositionCollateral(bytes32 positionID, uint256 collateralChange)
        external
        onlyPositionOwner(positionID)
    {
        Position storage position = _getPosition(positionID);
        if (!_canChangeCollateral(positionID, collateralChange, false)) {
            revert CannotChangeCollateral();
        }
        position.collateralInUSD =
            position.collateralInUSD - (collateralChange * _getUSDCPrice()) / (10 ** priceFeed.decimals("USDC"));
        uint256 feeOnCollateralChange = (
            calculatePositionCollateralChangeFee(collateralChange) * (10 ** priceFeed.decimals("USDC"))
                * (10 ** USDCToken.decimals())
        ) / _getUSDCPrice();
        USDCToken.safeTransferFrom(msg.sender, address(this), feeOnCollateralChange);
    }

    function liquidate(bytes32 positionID) external {
        Position memory position = getPosition(positionID);
        if (_isHealthyPosition(positionID) && position.positionOwner != msg.sender) {
            revert PositionHealthy();
        }
        uint256 usdcPrice = _getUSDCPrice();
        int256 pnl = _getPNL(positionID);
        uint256 amountToReturn;

        if (pnl < 0) {
            if (_absoluteValue(pnl) > position.collateralInUSD) {
                amountToReturn = position.collateralInUSD;
            } else {
                amountToReturn = position.collateralInUSD - _absoluteValue(pnl);
            }
        } else {
            amountToReturn = position.collateralInUSD + uint256(pnl);
        }
        amountToReturn = amountToReturn / 100;
        uint256 gasStipend = _getGasStipend();
        USDCToken.safeTransfer(
            position.positionOwner, (amountToReturn * (10 ** priceFeed.decimals("USDC"))) / usdcPrice
        );
        USDCToken.safeTransfer(msg.sender, gasStipend);

        delete openPositons[positionID];
    }

    function _getUsableBalance() internal returns (uint256) {
        uint256 currentBalance = USDCToken.balanceOf(address(this));
        return (currentBalance * MAX_ALLOWED_BPS) / TOTAL_BPS;
    }

    function _getBTCPrice() internal view returns (uint256) {
        int256 price = priceFeed.getPrice("WBTC");
        return uint256(price);
    }

    function _getUSDCPrice() internal view returns (uint256) {
        int256 price = priceFeed.getPrice("USDC");
        return uint256(price);
    }

    function _getETHPrice() internal view returns (uint256) {
        int256 price = priceFeed.getPrice("ETH");
        return uint256(price);
    }

    function _getPNL(bytes32 positionID) public view returns (int256) {
        Position memory position = _getPosition(positionID);
        uint256 btcPrice = _getBTCPrice() / (10 ** priceFeed.decimals("WBTC"));
        uint256 currentPositionPrice = position.size * btcPrice;
        if (position.isLong) {
            return
                int256(int256(currentPositionPrice) - int256(position.creationSizeInUSD * (10 ** wBTCToken.decimals())));
        }

        return int256(int256(position.creationSizeInUSD) - int256(currentPositionPrice * (10 ** wBTCToken.decimals())));
    }

    function getSystemPNL() public view returns (int256) {
        return getLongPNL() + getShortPNL();
    }

    function getLongPNL() public view returns (int256) {
        uint256 btcPrice = _getBTCPrice() / priceFeed.decimals("WBTC");
        return int256(initialBTCInUSDLong) - int256(btcSizeOpenedLong * btcPrice);
    }

    function getShortPNL() public view returns (int256) {
        uint256 btcPrice = _getBTCPrice() / priceFeed.decimals("WBTC");
        return int256(btcSizeOpenedShort * btcPrice) - int256(initialBTCInUSDShort);
    }

    function getPosition(bytes32 positionID) public view returns (Position memory) {
        return openPositons[positionID];
    }

    function _getPosition(bytes32 positionID) internal view returns (Position storage) {
        return openPositons[positionID];
    }

    function _isHealthyPosition(bytes32 positionID) internal view returns (bool) {
        int256 pnl = _getPNL(positionID);
        Position memory position = getPosition(positionID);
        uint256 adjustedCollateral;
        if (pnl < 0) {
            adjustedCollateral = position.collateralInUSD - _absoluteValue(pnl);
        } else {
            adjustedCollateral = position.collateralInUSD + uint256(pnl);
        }
        console.log("Adjusted Collateral : %d", adjustedCollateral);
        console.logInt(pnl);
        uint256 btcPrice = _getBTCPrice() / (10 ** priceFeed.decimals("WBTC"));
        console.log(" BTC Price: %d", btcPrice);
        uint256 leverage = (position.size * btcPrice) / (adjustedCollateral * (10 ** wBTCToken.decimals()));
        console.log("leverage : %d", leverage);
        return leverage <= MAX_LEVERAGE;
    }

    function _getPositionHash(address owner, uint256 collateralInUSD, uint256 sizeInUSD, bool isLong)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(owner, collateralInUSD, sizeInUSD, isLong));
    }

    function _getGasStipend() public view returns (uint256 amount) {
        uint256 usdcPrice = _getUSDCPrice();
        amount = (GAS_STIPEND * (10 ** USDCToken.decimals()) * (10 ** priceFeed.decimals("USDC"))) / usdcPrice;
    }

    function _absoluteValue(int256 value) internal pure returns (uint256) {
        return uint256(value >= 0 ? value : -value);
    }

    function _canChangeCollateral(bytes32 positionID, uint256 sizeChange, bool isIncement) public view returns (bool) {
        Position memory position = getPosition(positionID);
        int256 pnl = _getPNL(positionID);
        uint256 adjustedCollateral;
        if (pnl < 0) {
            if (isIncement) {
                adjustedCollateral =
                    (position.collateralInUSD + sizeChange) * (10 ** wBTCToken.decimals()) - _absoluteValue(pnl);
            } else {
                adjustedCollateral =
                    (position.collateralInUSD - sizeChange) * (10 ** wBTCToken.decimals()) - _absoluteValue(pnl);
            }
        } else {
            if (isIncement) {
                adjustedCollateral =
                    (position.collateralInUSD + sizeChange) * (10 ** wBTCToken.decimals()) + uint256(pnl);
            } else {
                adjustedCollateral =
                    (position.collateralInUSD - sizeChange) * (10 ** wBTCToken.decimals()) + uint256(pnl);
            }
        }
        if (adjustedCollateral == 0) return false;
        uint256 btcPrice = _getBTCPrice() / 10 ** wBTCToken.decimals();
        uint256 leverage = (position.size * btcPrice) / (adjustedCollateral);
        console.log("leverage: %d", leverage);
        console.log("adjusted collateral %d", adjustedCollateral);
        console.log("btcPrice %d", btcPrice);

        return leverage <= MAX_LEVERAGE;
    }

    function _canChangeSize(bytes32 positionID, uint256 sizeChange, bool isIncerement) internal view returns (bool) {
        Position memory position = getPosition(positionID);
        int256 pnl = _getPNL(positionID);

        uint256 adjustedCollateral;
        if (pnl < 0) {
            adjustedCollateral = position.collateralInUSD - _absoluteValue(pnl);
        } else {
            adjustedCollateral = position.collateralInUSD + uint256(pnl);
        }

        if (adjustedCollateral == 0) {
            return false;
        }
        uint256 adjustedSize;

        if (isIncerement) {
            adjustedSize += sizeChange;
        } else {
            adjustedSize -= sizeChange;
        }
        if (adjustedSize == 0) return false;

        uint256 leverage = adjustedSize / adjustedCollateral;
        return leverage <= MAX_LEVERAGE;
    }

    function _getBorrowingFee(bytes32 positionID) internal view returns (uint256) {
        Position memory position = _getPosition(positionID);
        return (position.size * (block.timestamp - position.creationTime)) / borrowingPerSecond;
    }
}
