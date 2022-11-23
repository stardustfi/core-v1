// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;
import "./IPriceOracle.sol";

contract DummyPrice is IPriceOracle {
    constructor() {}

    function getAssetPrice(address asset)
        external
        pure
        override
        returns (uint256)
    {
        return uint256(0);
    }
}
