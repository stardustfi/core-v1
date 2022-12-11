// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0;
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {ERC4626} from "solmate/src/mixins/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pool} from "./Pool.sol";

/// @notice Simple version of lending pool with Vault logic, actions controlled by an owner (likely a msig)
contract SimplePool is Ownable, ERC4626 {
    using SafeMath for uint256;
    using SafeERC20 for ERC20;

    struct WithdrawReq {
        uint256 shares;
        address receiver;
        address owner;
    }

    event WithdrawRequest(address withdrawAddress, uint256 withdrawAmount);
    WithdrawReq[] public withdrawalQueue;

    Pool public pool;
    ERC20 public borrowToken;

    //////////////////////////////////////////////////////////////
    ///                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////

    /// @notice Constructor
    /// @param _pool address of the pool contract
    /// @param _borrowToken Address of Borrow Token
    constructor(
        Pool _pool,
        ERC20 _borrowToken
    ) ERC4626(_borrowToken, "Bidding Pool", "BIDPOOL") {
        pool = _pool;
        borrowToken = _borrowToken;
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

    function maxDeposit(
        address
    ) public view virtual override returns (uint256) {}

    function maxMint(address) public view virtual override returns (uint256) {}

    function maxWithdraw(
        address owner
    ) public view virtual override returns (uint256) {}

    function maxRedeem(
        address owner
    ) public view virtual override returns (uint256) {}

    /// @notice Executes withdrawal queue
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
    /// @param _borrower Borrower address
    /// @param _collateralToken The collateral token
    /// @param _collateralAmount The collateral amount
    /// @param _borrowToken The token being borrowed
    /// @param _borrowAmount The amount of borrow token being borrowed
    /// @param _expiryTime The expiry of the loan
    function poolFill(
        address _borrower,
        address _collateralToken,
        uint256 _collateralAmount,
        address _borrowToken,
        uint256 _borrowAmount,
        uint256 _expiryTime
    ) public withdrawalRequest onlyOwner {
        pool.fill(
            _borrower,
            _collateralToken,
            _collateralAmount,
            _borrowToken,
            _borrowAmount,
            _expiryTime
        );
    }

    /// @notice Claims collateral from a loan position if there is a default.
    /// @dev Claim logic is handled in the pool contract, lazy claim
    /// @param _borrower Borrower address
    /// @param _collateralToken The collateral token
    /// @param _collateralAmount The collateral amount
    /// @param _borrowToken The token being borrowed
    /// @param _borrowAmount The amount of borrow token being borrowed
    /// @param _expiryTime The expiry of the loan
    function poolClaim(
        address _borrower,
        address _collateralToken,
        uint256 _collateralAmount,
        address _borrowToken,
        uint256 _borrowAmount,
        uint256 _expiryTime
    ) public onlyOwner {
        pool.claim(
            _borrower,
            _collateralToken,
            _collateralAmount,
            _borrowToken,
            _borrowAmount,
            _expiryTime
        );
        ERC20(_collateralToken).transfer(msg.sender, _collateralAmount);
    }
}
