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

    modifier verifyLoanCreation(
        address _collateralToken,
        uint256 _collateralAmount,
        uint256 _expiryTime
    ) {
        if (_collateralAmount == 0) {
            revert InvalidCollateralAmount(_collateralAmount);
        }
        if (_expiryTime == 0) {
            revert InvalidExpiryTime(_expiryTime);
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               EXTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Create a Loan that borrows baseToken as a borrower putting a shitcoin as collateral
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

        // transfer in the collateral - TODO: Create a signed tx that is spent later
        IERC20(_collateralToken).safeTransferFrom(
            msg.sender,
            address(this),
            _collateralAmount
        );
    }

    /// @dev Cancel a Loan you created
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
        delete positions[key];
        for (uint256 i = 0; i < positionIds.length; i++) {
            if (positionIds[i] == key) {
                positionIds[i] = positionIds[positionIds.length - 1];
                positionIds.pop();
                break;
            }
        }
        // transfer in the collateral - TODO: Create a signed tx that is spent later
        IERC20(_collateralToken).safeTransfer(msg.sender, _collateralAmount);
    }

    /// @dev Fill a loan as a lender putting up USDC for a shitcoin
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

        // TODO: Spend the signed tx, if we are implementing the signed tx

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

    function amountToPayoff(bytes32 key) public view returns (uint256) {
        uint256 subtotal = positions[key].borrowAmount +
            ((block.timestamp - positions[key].startTime) * ANNUAL_RATE);

        // Check if the loan is expired and incurs penalty
        if (block.timestamp > positions[key].expiryTime) {
            subtotal =
                subtotal +
                ((block.timestamp - positions[key].expiryTime) *
                    COLLATERAL_EXPIRY_RATE);
        }
        return subtotal / (SECONDS_IN_YEAR * BASIS_POINTS_DIVISOR);
    }

    /// @dev can be called before expiry
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

        // calculate interest rate for borrower and transfer to lender
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

        // Change struct
        Loan storage newLoan = positions[key];
        newLoan.borrower = msg.sender;
        newLoan.isSettled = true;
    }

    /// @dev Claim the shitcoin whose borrow of USDC was not repaid by borrower
    /// @dev can be called after expiry, although can receive the accrued penalty interest if so desired.
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

    function getPositionKey(
        address _account,
        address _collateralToken,
        uint256 _collateralAmount,
        address _borrowToken,
        uint256 _borrowAmount,
        uint256 _expiryTime
    ) public pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    _account,
                    _collateralToken,
                    _collateralAmount,
                    _borrowToken,
                    _borrowAmount,
                    _expiryTime
                )
            );
    }
}
