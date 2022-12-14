// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0;
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {ERC4626} from "solmate/src/mixins/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPriceOracle} from "./integrations/IPriceOracle.sol";
import {Pool} from "./Pool.sol";

contract PoolFill is Ownable, ERC4626 {
    using SafeMath for uint256;
    using SafeERC20 for ERC20;

    struct Auction {
        address collateral;
        address highestBidder;
        uint256 reservePrice;
        uint256 startTime;
        uint256 highestBid;
        uint256 collateralAmount;
    }

    struct WithdrawReq {
        uint256 shares;
        address receiver;
        address owner;
    }

    event WithdrawRequest(address withdrawAddress, uint256 withdrawAmount);

    mapping(uint256 => Auction) public auctions;
    // mapping(bytes32 => Pool.Loan) public positions;
    mapping(address => bool) public isCollateral;
    mapping(address => uint8) public LTVs;

    WithdrawReq[] public withdrawalQueue;

    uint256 public maxDuration;
    uint256 public auctionDuration = 1 days;
    uint256 public AuctionID = 0;
    uint8 public withdrawalID = 0;

    error InvalidRedeem(address redeemer, uint256 amount);
    error BorrowNotCollateralized(address borrower, address collateral);
    error AuctionEnded(uint256 auctionID);
    error AuctionNotEnded(uint256 auctionID);
    error AuctionBidTooLow(uint256 auctionID);

    Pool public pool;
    IPriceOracle public oracle;
    ERC20 public borrowToken;

    //////////////////////////////////////////////////////////////
    ///                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////
    /// @notice Constructor
    /// @param _pool address of the pool contract
    /// @param _oracle address of the oracle contract. Should be of type IPriceOracle
    /// @param _borrowToken Address of Borrow Token
    /// @param _maxDuration Max duration of loan
    constructor(
        Pool _pool,
        IPriceOracle _oracle,
        ERC20 _borrowToken,
        uint256 _maxDuration
    ) ERC4626(_borrowToken, "Bidding Pool", "BIDPOOL") {
        pool = _pool;
        oracle = _oracle;
        borrowToken = _borrowToken;
        maxDuration = _maxDuration;
        borrowToken.approve(address(pool), type(uint256).max);
    }

    //////////////////////////////////////////////////////////////
    ///                        ERC4626 OVERRIDES
    //////////////////////////////////////////////////////////////
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public virtual override returns (uint256 shares) {}

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public virtual override returns (uint256 assets) {}

    function totalAssets() public view virtual override returns (uint256) {}

    function afterDeposit(
        uint256 assets,
        uint256 /*shares*/
    ) internal virtual override {}

    function maxDeposit(address)
        public
        view
        virtual
        override
        returns (uint256)
    {}

    function maxMint(address) public view virtual override returns (uint256) {}

    function maxWithdraw(address owner)
        public
        view
        virtual
        override
        returns (uint256)
    {}

    function maxRedeem(address owner)
        public
        view
        virtual
        override
        returns (uint256)
    {}

    // /// @notice Executes withdrawal request
    modifier withdrawalRequest() {
        _;
        for (uint256 i = withdrawalQueue.length; i > 0; i--) {
            WithdrawReq memory withReq = withdrawalQueue[i];
            if (borrowToken.balanceOf(address(this)) < withReq.shares) {
                // Not enough balance to withdraw, can force withdraw by calling Withdraw method on ERC4626
                /// @notice could break things
                continue;
            } else if (withReq.shares <= ERC4626.maxRedeem(withReq.owner)) {
                // Call _redeem on ERC4626 instead of redeem
                redeem(withReq.shares, withReq.receiver, withReq.owner);
                delete withdrawalQueue[i];
            }
        }
    }

    // /*//////////////////////////////////////////////////////////////
    //                             POOL FUNCTIONS
    // //////////////////////////////////////////////////////////////
    /// @notice Fills a set loan position if it matches standard
    function poolFill(
        address _borrower,
        address _collateralToken,
        uint256 _collateralAmount,
        address _borrowToken,
        uint256 _borrowAmount,
        uint256 _expiryTime
    ) public withdrawalRequest {
        if (
            !_isBorrowCollateralized(
                _collateralToken,
                _collateralAmount,
                _borrowToken,
                _borrowAmount,
                _expiryTime
            )
        ) {
            revert BorrowNotCollateralized(_borrower, _collateralToken);
        }

        pool.fill(
            _borrower,
            _collateralToken,
            _collateralAmount,
            _borrowToken,
            _borrowAmount,
            _expiryTime
        );
    }

    // /// @notice Claims collateral from a loan position if not repaid
    // /// claim logic is handled in the pool contract, lazy claim
    // function poolClaim(
    //     address _borrower,
    //     address _collateralToken,
    //     uint256 _collateralAmount,
    //     address _borrowToken,
    //     uint256 _borrowAmount,
    //     uint256 _expiryTime
    // ) public {
    //     pool.claim(_borrower,
    //         _collateralToken,
    //         _collateralAmount,
    //         _borrowToken,
    //         _borrowAmount,
    //         _expiryTime);
    //     _liquidateCollateral(_collateral);
    // }

    /// @notice Changes oracle address
    function changeOracle(address _oracle) public onlyOwner {
        oracle = IPriceOracle(_oracle);
    }

    /// @notice Changes LTV for a collateral
    /// @param _collateral The collateral to change LTV for
    /// @param _LTV The new LTV, uses only 2 decimals
    function changeLTV(address _collateral, uint8 _LTV) public onlyOwner {
        LTVs[_collateral] = _LTV;
    }

    // /// @notice Creates Withdrawal request
    // /// @param _amount The amount to withdraw
    // function requestWithdraw(uint256 _amount) public {
    //     if(_amount <= maxRedeem(msg.sender)){
    //         revert InvalidRedeem(msg.sender, _amount);
    //     }
    //     emit WithdrawalRequested(msg.sender, _amount);
    //     withdrawalQueue[withdrawalID] = WithdrawReq(msg.sender, _amount);
    //     withdrawalID++;
    // }

    // /*//////////////////////////////////////////////////////////////
    //                             AUCTION FUNCTIONS
    // //////////////////////////////////////////////////////////////

    // function bidCollateral(uint256 _auctionID, uint256 _amount) public {
    //     Auction memory auction = auctions[_auctionID];

    //     if(block.timestamp < auction.startTime.add(auctionDuration)){
    //         revert AuctionNotEnded(_auctionID);
    //     }
    //     if(_amount > auction.highestBid) {AuctionBidTooLow(_auctionID)};
    //     // Transfer bid to auction contract
    //     borrowToken.transferFrom(msg.sender, address(this), _amount);
    //     if (auction.highestBidder != address(0)) {
    //         // Return bid to previous highest bidder
    //         borrowToken.transfer(auction.highestBidder, auction.highestBid);
    //     }
    //     auctions[_auctionID].highestBid = _amount;
    //     auctions[_auctionID].highestBidder = msg.sender;
    // }

    // function endAuction(uint256 _auctionID) public {
    //     Auction memory auction = auctions[_auctionID];
    //     // Auction must be over
    //     // Not good for rebasing tokens
    //     if(block.timestamp > auction.start) {AuctionNotEnded(_auctionID);}

    //     if (
    //         auction.highestBidder != address(0) ||
    //         (auction.highestBid >= auction.reservePrice)
    //     ) {
    //         // Transfer collateral to Owner to liquidate
    //         IERC20(auction.collateral).transfer(
    //             owner,
    //             auction.collateralAmount
    //         );
    //     } else {
    //         // Transfer collateral to highest bidder
    //         IERC20(auction.collateral).transfer(
    //             auction.highestBidder,
    //             auction.collateralAmount
    //         );
    //     }
    //     delete auctions[_auctionID];
    // }

    // /*//////////////////////////////////////////////////////////////
    //                         INTERNAL LOGIC
    // //////////////////////////////////////////////////////////////*/

    // /// @notice Modified redeem function for withdrawal requests
    // function _redeem(uint256 shares, address receiver)
    //     internal
    //     returns (uint256 assets)
    // {
    //     // Check for rounding error since we round down in previewRedeem.
    //     if((assets = previewRedeem(shares)) != 0) {revert InvalidRedeem(msg.sender, shares);}

    //     //beforeWithdraw(assets, shares);

    //     _burn(receiver, shares);

    //     emit Withdraw(msg.sender, receiver, owner, assets, shares);

    //     asset.safeTransfer(receiver, assets);
    // }

    function _isBorrowCollateralized(
        address _collateral,
        uint256 _collateralAmount,
        address _borrowToken,
        uint256 _borrowAmount,
        uint256 _expiryTime
    ) internal view returns (bool) {
        // get value of collateral net LTV
        uint256 collateralValue = (oracle.getAssetPrice(_collateral) *
            _collateralAmount *
            LTVs[_collateral]) / pool.BASIS_POINTS_DIVISOR();

        // get value of requested borow
        uint256 borrowValue = (oracle.getAssetPrice(_borrowToken) *
            _borrowAmount) / pool.BASIS_POINTS_DIVISOR();

        // compare, return bool
        return collateralValue >= borrowValue && block.timestamp < _expiryTime;
    }

    // /// @notice Begins an auction for a loan position
    // function beginAuction(address _collateral, uint256 _reservePrice) internal {
    //     // Vulnerable if token is reentrant
    //     auctions[AuctionID] = Auction(
    //         _collateral,
    //         _reservePrice,
    //         block.timestamp,
    //         0,
    //         address(0),
    //         IERC20(_collateral).balanceOf(address(this))
    //     );
    //     AuctionID++;
    // }

    // /// @notice Liquidates collateral from a loan position
    // function _liquidateCollateral(address _collateral) internal {
    //     uint256 reservePrice = oracle.getAssetPrice(_collateral) *
    //         LTVs[_collateral];
    //     if (reservePrice == 0) {
    //         IERC20(_collateral).safeTransfer(
    //             owner,
    //             IERC20(_collateral).balanceOf(address(this))
    //         );
    //     } else {
    //         beginAuction(_collateral, reservePrice);
    //     }
    // }
}
