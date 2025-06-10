// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

interface IAaveLoopSwapCallee {
    /// @notice If non-empty data is provided to `swap()`, then this callback function
    /// is invoked on the `to` address, allowing flash-swaps (withdrawing output before
    /// sending input.
    /// @dev This callback mechanism is designed to be as similar as possible to Uniswap2.
    function aaveLoopSwapCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external;
}
