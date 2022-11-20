// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

interface IPriceOracle {
    /// @notice returns the price of the given asset in USD, scaled by 1e18
    /// @param asset the asset to get the price of
    /// @return the asset price in USD, scaled by 1e18
    function getAssetPrice(address asset) external view returns (uint256);
}
