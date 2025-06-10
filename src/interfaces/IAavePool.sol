// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function getReserveAToken(address asset) external view returns (address);
    function getReserveVariableDebtToken(address asset) external view returns (address);

    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;

    function setUserEMode(uint8 categoryId) external;
    function setUserUseReserveAsCollateral(address asset, bool useAsCollateral) external;

    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
        external
        returns (uint256);

    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata interestRateModes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

