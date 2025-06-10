// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IAToken {
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
    function balanceOf(address user) external view returns (uint256);
    function approveDelegation(address delegatee, uint256 amount) external;
    
}
