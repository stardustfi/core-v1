// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "hardhat/console.sol";

contract Pool is Ownable {
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
        address borrowToken;
        uint256 borrowAmount;
        uint256 startTime;
        uint256 expiryTime;
    }

    uint256 public ANNUAL_RATE = 2000;
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    uint256 public constant COLLATERAL_EXPIRY_RATE = 20000; //APR on collateral for borrower who doesn't repay loan
    uint256 public constant SECONDS_IN_YEAR = 365 * 24 * 60 * 60;

    mapping(bytes32 => Loan) public positions;
    bytes32[] public positionIds;

    address[] public borrows;
    uint256 public numBorrows;

    error InvalidPosition(bytes32 key);
    error InvalidCollateral(address collateralToken);
    error InvalidCollateralAmount(uint256 collateralAmount);
    error InvalidExpiryTime(uint256 expiryTime);
    error PositionAlreadyCreated(bytes32 key);
    error PositionAlreadyExpired(bytes32 key);
    error PositionAlreadyFilled(bytes32 key);
    error PositionAlreadySettled(bytes32 key);
    error SafeTransferFailed(address to, uint256 amount);

    /// @notice Provides
    /// @return All the loans
    function fetchAllPositions() external view returns (Loan[] memory) {
        Loan[] memory allPositions = new Loan[](positionIds.length);
        for (uint256 i = 0; i < positionIds.length; i++) {
            allPositions[i] = positions[positionIds[i]];
        }
        return allPositions;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() {}

    /// @dev Returns whether the loan has nonzero collateral or expiry
    /// @param _collateralToken The collateral token
    /// @param _collateralAmount The collateral amount
    /// @param _expiryTime The expiry of the loan (usually some date in the Future)
    modifier verifyLoanCreation(
        address _collateralToken,
        uint256 _collateralAmount,
        uint256 _expiryTime
    ) {
        if (_collateralAmount == 0) {
            revert InvalidCollateralAmount(_collateralAmount);
        }
        if (_expiryTime < block.timestamp) {
            // Loan is in the past. Loan can expire same block if it's essentially a market sell order
            revert InvalidExpiryTime(_expiryTime);
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               EXTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Create a Loan that borrows baseToken as a borrower putting a s*coin as collateral
    /// @param _collateralToken The collateral token
    /// @param _collateralAmount The collateral amount
    /// @param _borrowToken The token being borrowed (Digit agnostic)
    /// @param _borrowAmount The amount of borrow token being borrowed – ideally no rebasing tokens
    /// @param _expiryTime The expiry of the loan (usually some date in the Future)
    function create(
        address _collateralToken,
        uint256 _collateralAmount,
        address _borrowToken,
        uint256 _borrowAmount,
        uint256 _expiryTime
    )
        external
        verifyLoanCreation(_collateralToken, _collateralAmount, _expiryTime)
    {
        // get position
        bytes32 key = getPositionKey(
            msg.sender,
            _collateralToken,
            _collateralAmount,
            _borrowToken,
            _borrowAmount,
            _expiryTime
        );
        if (positions[key].collateral != address(0)) {
            revert PositionAlreadyCreated(key);
        }

        // write order in storage
        Loan storage newLoan = positions[key];
        newLoan.borrower = msg.sender;
        newLoan.isActive = true;
        newLoan.collateral = _collateralToken;
        newLoan.collateralAmount = _collateralAmount;
        newLoan.borrowToken = _borrowToken;
        newLoan.borrowAmount = _borrowAmount;
        newLoan.expiryTime = _expiryTime;
        positionIds.push(key);

        // transfer in the collateral - (v1): Create a signed tx that is spent later
        IERC20(_collateralToken).safeTransferFrom(
            msg.sender,
            address(this),
            _collateralAmount
        );
    }

    /// @dev Cancel a Loan borrower has created
    /// @param _collateralToken The collateral token
    /// @param _collateralAmount The collateral amount
    /// @param _borrowToken The token being borrowed
    /// @param _borrowAmount The amount of borrow token being borrowed
    /// @param _expiryTime The expiry of the loan
    function cancel(
        address _collateralToken,
        uint256 _collateralAmount,
        address _borrowToken,
        uint256 _borrowAmount,
        uint256 _expiryTime
    ) external {
        // get position
        bytes32 key = getPositionKey(
            msg.sender,
            _collateralToken,
            _collateralAmount,
            _borrowToken,
            _borrowAmount,
            _expiryTime
        );

        // Check if position has been filled or not already
        if (!positions[key].isActive) {
            revert PositionAlreadyFilled(key);
        }

        delete positions[key];
        for (uint256 i = 0; i < positionIds.length; i++) {
            if (positionIds[i] == key) {
                positionIds[i] = positionIds[positionIds.length - 1];
                positionIds.pop();
                break;
            }
        }
        // transfer in the collateral - (v1): Create a signed tx that is spent later
        IERC20(_collateralToken).safeTransfer(msg.sender, _collateralAmount);
    }

    /// @dev Fill a loan as a lender putting up USDC for a shitcoin
    /// @param _borrower Borrower address
    /// @param _collateralToken The collateral token
    /// @param _collateralAmount The collateral amount
    /// @param _borrowToken The token being borrowed
    /// @param _borrowAmount The amount of borrow token being borrowed
    /// @param _expiryTime The expiry of the loan
    function fill(
        address _borrower,
        address _collateralToken,
        uint256 _collateralAmount,
        address _borrowToken,
        uint256 _borrowAmount,
        uint256 _expiryTime
    ) external {
        // get position
        bytes32 key = getPositionKey(
            _borrower,
            _collateralToken,
            _collateralAmount,
            _borrowToken,
            _borrowAmount,
            _expiryTime
        );
        if (positions[key].collateral == address(0)) {
            revert InvalidPosition(key);
        }
        if (!positions[key].isActive) {
            revert PositionAlreadyFilled(key);
        }
        if (positions[key].expiryTime < block.timestamp) {
            revert PositionAlreadyExpired(key);
        }

        // get requested borrow amount
        uint256 requestedAmount = positions[key].borrowAmount;

        // (v1): Spend the signed tx, if we are implementing the signed tx

        // transfer USDC to borrower
        IERC20(_borrowToken).safeTransferFrom(
            msg.sender,
            address(this),
            requestedAmount
        );
        IERC20(_borrowToken).safeTransfer(_borrower, requestedAmount);

        // write to storage
        Loan storage newLoan = positions[key];
        newLoan.lender = msg.sender;
        newLoan.isActive = true;
        newLoan.startTime = block.timestamp;
    }

    /// @dev Provided a key, provide the details on how much to pay back at present
    /// @param key the keccak encoded loan
    /// @return PayoffAmount the amount to pay back
    function amountToPayoff(
        bytes32 key
    ) public view returns (uint256 PayoffAmount) {
        uint256 subtotal = positions[key].borrowAmount +
            ((block.timestamp - positions[key].startTime) * ANNUAL_RATE);

        // Check if the loan is expired and incurs penalty
        if (block.timestamp > positions[key].expiryTime) {
            subtotal =
                subtotal +
                ((block.timestamp - positions[key].expiryTime) *
                    COLLATERAL_EXPIRY_RATE);
        }
        PayoffAmount = subtotal / (SECONDS_IN_YEAR * BASIS_POINTS_DIVISOR);
    }

    /// @dev Repay ends loan by full repayment, and can be called before loan expiry
    /// @param _borrower Borrower address
    /// @param _collateralToken The collateral token
    /// @param _collateralAmount The collateral amount
    /// @param _borrowToken The token being borrowed
    /// @param _borrowAmount The amount of borrow token being borrowed
    /// @param _expiryTime The expiry of the loan
    function repay(
        address _borrower,
        address _collateralToken,
        uint256 _collateralAmount,
        address _borrowToken,
        uint256 _borrowAmount,
        uint256 _expiryTime
    ) external {
        // get position
        bytes32 key = getPositionKey(
            _borrower,
            _collateralToken,
            _collateralAmount,
            _borrowToken,
            _borrowAmount,
            _expiryTime
        );
        if (positions[key].collateral == address(0)) {
            revert InvalidPosition(key);
        }
        if (positions[key].isSettled) {
            revert PositionAlreadySettled(key);
        }

        // Calculate interest + principal for borrower and transfer to lender
        uint256 _amountToPayoff = amountToPayoff(key);
        IERC20(_borrowToken).safeTransferFrom(
            msg.sender,
            address(this),
            _amountToPayoff
        );
        IERC20(_borrowToken).safeTransfer(
            positions[key].lender,
            _amountToPayoff
        );

        // Transfer collateral to borrower
        IERC20(_collateralToken).safeTransfer(
            _borrower,
            positions[key].collateralAmount
        );

        // Update struct
        Loan storage newLoan = positions[key];
        newLoan.borrower = msg.sender;
        newLoan.isSettled = true;
    }

    /// @dev Claim the collateral where borrow hasn't been repaid after expiry
    /// @dev Claim can be called after expiry, and can receive the accrued penalty interest if so desired.
    /// @param _borrower Borrower address
    /// @param _collateralToken The collateral token
    /// @param _collateralAmount The collateral amount
    /// @param _borrowToken The token being borrowed
    /// @param _borrowAmount The amount of borrow token being borrowed
    /// @param _expiryTime The expiry of the loan
    function claim(
        address _borrower,
        address _collateralToken,
        uint256 _collateralAmount,
        address _borrowToken,
        uint256 _borrowAmount,
        uint256 _expiryTime
    ) public {
        // get position
        bytes32 key = getPositionKey(
            _borrower,
            _collateralToken,
            _collateralAmount,
            _borrowToken,
            _borrowAmount,
            _expiryTime
        );
        if (positions[key].collateral == address(0)) {
            revert InvalidPosition(key);
        }
        if (positions[key].isSettled) {
            revert PositionAlreadySettled(key);
        }

        // Mark as claimed
        positions[key].isSettled = true;

        // Claim the collateral
        IERC20(positions[key].collateral).safeTransfer(
            positions[key].lender,
            positions[key].collateralAmount
        );

        delete positions[key];
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL LOGIC
    //////////////////////////////////////////////////////////////*/
    /// @dev Encode loan details into a bytes32
    /// @param _borrower Borrower address
    /// @param _collateralToken The collateral token
    /// @param _collateralAmount The collateral amount
    /// @param _borrowToken The token being borrowed
    /// @param _borrowAmount The amount of borrow token being borrowed
    /// @param _expiryTime The expiry of the loan
    /// @return Return the encoded version
    function getPositionKey(
        address _borrower,
        address _collateralToken,
        uint256 _collateralAmount,
        address _borrowToken,
        uint256 _borrowAmount,
        uint256 _expiryTime
    ) public pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    _borrower,
                    _collateralToken,
                    _collateralAmount,
                    _borrowToken,
                    _borrowAmount,
                    _expiryTime
                )
            );
    }
}
