// SPDX-License-Identifier: MIT
// pseudo code
pragma solidity >=0.8.0;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./Pool.sol";

/// @notice This contract is used for offchain logic but onchain atomic Fills
/// Should be used with a multicall
contract biddingOffer {
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
    uint256 public loans = 0;
    address public owner;
    error InvalidPosition(bytes32 key);
    error LendingSignatureInvalid(address lender);
    error DeadlinePassed(address lender);
    mapping(bytes32 => Loan) public positions;

    mapping(bytes32 => address) public loanBook;

    constructor(address _poolAddress) {
        poolAddress = Pool(_poolAddress);
        owner = msg.sender;
    }

    /// @notice Fills a set loan position if lender sig is valid
    function poolFill(
        address _lender,
        address _borrower,
        address _collateralToken,
        uint256 _collateralAmount,
        address _borrowToken,
        uint256 _borrowAmount,
        uint256 _expiryTime,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public {
        require(
            checkSig(_account, _collateral, _borrowToken),
            "Lender Signature is not valid"
        );
        IERC20(_borrowToken).transferFrom(
            _lender,
            address(this),
            positions[keccak256(abi.encode(_account, _collateral))].borrowAmount
        );
        poolAddress.fill(_account, _collateral, _borrowToken);
        loanBook[getPositionKey(_account, _collateral, _borrowToken)] = msg
            .sender;
    }

    /// @notice Claim collateral if there is a default

    function poolClaim(
        // could replace with just bytes32 key, doing the getPositionKey() in the frontend
        address _account,
        address _collateral,
        address _borrowToken
    ) public {
        // Check that the loan was made by the corresponding lender
        bytes32 key = getPositionKey(
            msg.sender,
            _collateralToken,
            _collateralAmount,
            _borrowToken,
            _borrowAmount,
            _expiryTime
        );
        Loan memory newloan = positions[key];
        require(newloan.lender == msg.sender, "Not Lender for Loan");
        poolAddress.claim(_account, _collateral, _borrowToken);
        IERC20(_collateral).transfer(msg.sender, newloan.collateralAmount);
    }

    /// @notice Retrieve funds if loan is paid back.
    // TODO fix this up, also the pool contract deleted the loan
    function poolRefund(
        address _borrower,
        address _collateralToken,
        uint256 _collateralAmount,
        address _borrowToken,
        uint256 _borrowAmount,
        uint256 _expiryTime,
        uint256 _loanID
    ) public {
        bytes32 key = getPositionKey(
            msg.sender,
            _collateralToken,
            _collateralAmount,
            _borrowToken,
            _borrowAmount,
            _expiryTime
        );
        Loan memory newloan = positions[key];

        // Check that the loan was made by the corresponding lender
        require(newloan.lender == msg.sender, "Not Lender for Loan");
        // Lazy evaluation, obvious exploit if collateral for one loan is borrowable token for another
        // Issue with borrowAmount is that accrued interest not included
        // also can't use amountToPayoff since Loan obj is deleted
        positions.transfer(msg.sender, _borrowToken.balanceOf(address(this)));
    }

    function checkSig(
        address _account,
        address _collateralToken,
        address _borrowToken,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public view {
        require(block.timestamp < deadline, "deadline over");
        require(
            ecrecover(
                // Need to have the ABI encoded message validated to the corresponding loan
                // TODO @albert fix this logic to match the correct loan
                // ngl might be good to pass in a bytes32 in the frontend instead of these
                keccak256(
                    abi.encodePacked(
                        "\x19Ethereum Signed Message:\n111",
                        account,
                        collateralToken,
                        borrowToken,
                        deadline,
                        block.chainid,
                        address(lender)
                    )
                ),
                v,
                r,
                s
            ) == account,
            LendingSignatureInvalid(account)
        );
        require(loanBook[account] == false, "Loan has already been filled");
        // check no replay attack
        require(deadline > block.timestamp, DeadlinePassed(_lender));
        return true;
    }

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

    /// @notice Sweep tokens
    function sweep(address _token) public {
        require(msg.sender == owner, "not owner");
        IERC20(_token).transfer(
            msg.sender,
            IERC20(_token).balanceOf(address(this))
        );
    }
}
