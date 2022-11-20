// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@solmate/mixins/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPriceOracle} from "./IPriceOracle.sol";
import {Pool} from "../Pool.sol";

contract biddingPool is Ownable, ERC4626 {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    struct Loan {
        address borrower;
        address lender;
        bool isActive;
        bool isFilled;
        bool isSettled;
        address collateral;
        uint256 collateralAmount;
        uint256 borrowAmount;
        uint256 startTime;
        uint256 expiryTime;
    }

    struct Auction {
        address collateral;
        address highestBidder;
        uint256 reservePrice;
        uint256 startTime;
        uint256 highestBid;
        uint256 collateralAmount;
    }

    struct WithdrawReq {
        address withdrawAddress;
        uint256 withdrawAmount;
    }

    mapping(uint256 => Auction) public auctions;
    mapping(bytes32 => Loan) public positions;
    mapping(address => bool) public isCollateral;
    mapping(address => uint8) public LTVs;

    WithdrawReq[] public withdrawalQueue;
    uint256 public maxDuration;
    uint256 public auctionDuration = 1 days;
    uint256 public AuctionID = 0;
    uint8 public withdrawalID = 0;
    error InvalidPosition(bytes32 key);
    error AuctionEnded(uint256 auctionID);
    error AuctionNotEnded(uint256 auctionID);
    error AuctionBidTooLow(uint256 auctionID);

    address public poolAddress;
    address public oracle;
    address public borrowToken;

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    */
    //////////////////////////////////////////////////////////////
    /// @notice Constructor
    /// @param _PoolAddress address of the pool contract
    /// @param _oracle address of the oracle contract. Should be of type IPriceOracle
    /// @param BORROW_TOKEN Address of Borrow Token
    /// @param _maxDuration Max duration of loan

    constructor(
        address _PoolAddress,
        address _oracle,
        address BORROW_TOKEN,
        uint256 _maxDuration
    ) ERC4626(IERC20(BORROW_TOKEN), "Bidding Pool", "BIDPOOL") {
        poolAddress = Pool(_PoolAddress);
        oracle = IPriceOracle(_oracle);
        borrowToken = IERC20(BORROW_TOKEN);
        maxDuration = _maxDuration;
        borrowToken.approve(_PoolAddress, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                                POOL FUNCTIONS
    */
    //////////////////////////////////////////////////////////////

    /// @notice Fills a set loan position if it matches standard
    function poolFill(
        address _account,
        address _collateral,
        address _borrowToken
    ) public {
        require(
            _isBorrowCollateralized(_account, _collateral, _borrowToken),
            "Borrower is not collateralized"
        );
        _withdrawalRequest();
        poolAddress.fill(_account, _collateral, _borrowToken);
    }

    /// @notice Claims collateral from a loan position if not repaid
    /// claim logic is handled in the pool contract, lazy claim
    function poolClaim(
        address _account,
        address _collateral,
        address _borrowToken
    ) public {
        poolAddress.claim(_account, _collateral, _borrowToken);
        _liquidateCollateral(_collateral);
    }

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

    /// @notice Creates Withdrawal request
    /// @param _amount The amount to withdraw
    function requestWithdraw(uint256 _amount) public {
        require(_amount <= maxRedeem(msg.sender), "More redeem than max");
        withdrawalQueue[withdrawalID] = WithdrawReq(msg.sender, _amount);
        withdrawalID++;
    }

    /*//////////////////////////////////////////////////////////////
                                AUCTION FUNCTIONS
    */
    //////////////////////////////////////////////////////////////

    function bidCollateral(uint256 _auctionID, uint256 _amount) public {
        Auction memory auction = auctions[_auctionID];
        require(
            block.timestamp < auction.startTime.add(auctionDuration),
            AuctionEnded(_auctionID)
        );
        require(_amount > auction.highestBid, AuctionBidTooLow(_auctionID));
        // Transfer bid to auction contract
        borrowToken.transferFrom(msg.sender, address(this), _amount);
        if (auction.highestBidder != address(0)) {
            // Return bid to previous highest bidder
            borrowToken.transfer(auction.highestBidder, auction.highestBid);
        }
        auctions[_auctionID].highestBid = _amount;
        auctions[_auctionID].highestBidder = msg.sender;
    }

    function endAuction(uint256 _auctionID) public {
        Auction memory auction = auctions[_auctionID];
        // Auction must be over
        // Not good for rebasing tokens
        require(block.timestamp > auction.start, AuctionNotEnded(_auctionID));

        if (
            auction.highestBidder != address(0) ||
            (auction.highestBid >= auction.reservePrice)
        ) {
            // Transfer collateral to Owner to liquidate
            IERC20(auction.collateral).transfer(
                owner,
                auction.collateralAmount
            );
        } else {
            // Transfer collateral to highest bidder
            IERC20(auction.collateral).transfer(
                auction.highestBidder,
                auction.collateralAmount
            );
        }
        delete auctions[_auctionID];
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Modified redeem function for withdrawal requests
    function _redeem(uint256 shares, address receiver)
        internal
        returns (uint256 assets)
    {
        // Check for rounding error since we round down in previewRedeem.
        require((assets = previewRedeem(shares)) != 0, "ZERO_ASSETS");

        //beforeWithdraw(assets, shares);

        _burn(receiver, shares);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        asset.safeTransfer(receiver, assets);
    }

    /// @notice Executes withdrawal request
    function _withdrawalRequest() internal {
        for (uint256 i = withdrawalQueue.length; i > 0; i--) {
            WithdrawReq memory withReq = withdrawalQueue[i];
            if (
                IERC20.withdrawToken.balanceOf(address(this)) <
                withReq.withdrawAmount
            ) {
                // Not enough balance to withdraw, can force withdraw by calling Withdraw method on ERC4626
                /// @notice could break things
                continue;
            } else if (
                withReq.withdrawAmount <=
                ERC4626.maxRedeem(withReq.withdrawAddress)
            ) {
                // Call _redeem on ERC4626 instead of redeem
                _redeem(withReq.withdrawAddress, withReq.withdrawAmount);
                delete withdrawalQueue[i];
            }
        }
    }

    function _isBorrowCollateralized(
        address _account,
        address _collateral,
        address _borrowToken
    ) internal returns (bool) {
        // get position key
        bytes32 key = poolAddress.getPositionKey(
            _account,
            _collateral,
            _borrowToken
        );
        // gt loan information
        Loan memory loan = poolAddress.positions[key];

        // get value of collateral net LTV
        uint256 collateralValue = (oracle.getAssetPrice(loan.collateralAmount) *
            LTVs[loan.collateral]) / 10000;

        // get value of requested borow
        uint256 borrowValue = loan.borrowAmount;

        // check duration of loan
        uint256 duration = loan.expiryTime - loan.startTime;

        // compare, return bool
        return (collateralValue >= borrowValue && duration <= maxDuration);
    }

    /// @notice Begins an auction for a loan position
    function beginAuction(address _collateral, uint256 _reservePrice) internal {
        // Vulnerable if token is reentrant
        auctions[AuctionID] = Auction(
            _collateral,
            _reservePrice,
            block.timestamp,
            0,
            address(0),
            IERC20(_collateral).balanceOf(address(this))
        );
        AuctionID++;
    }

    function _liquidateCollateral(address _collateral) internal {
        uint256 reservePrice = oracle.getAssetPrice(_collateral);
        if (reservePrice == 0) {
            require(onlyOwner, "Collateral is not liquidatable");
            IERC20(_collateral).safeTransfer(
                msg.sender,
                IERC20(_collateral).balanceOf(address(this))
            );
        } else {
            beginAuction(_collateral, reservePrice);
        }
    }

    function getPositionKey(
        address _account,
        address _collateralToken,
        address _borrowToken
    ) public pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(_account, _collateralToken, _borrowToken)
            );
    }
}
