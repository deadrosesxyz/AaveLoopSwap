// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;

import {SafeERC20, IERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {Errors as EVKErrors} from "evk/EVault/shared/Errors.sol";

import {IAaveLoopSwap} from "../interfaces/IAaveLoopSwap.sol";
import {IAToken} from "../interfaces/IAToken.sol";
import {IAavePool} from "../interfaces/IAavePool.sol";


library FundsLib {
    using SafeERC20 for IERC20;

    error DepositFailure(bytes reason);

    /// @notice Approves tokens for a given vault, supporting both standard approvals and permit2

    function approveAsset(address variableDebtToken, address aave) internal {
        address asset = IAToken(variableDebtToken).UNDERLYING_ASSET_ADDRESS();

        IERC20(asset).forceApprove(aave, type(uint256).max);
    }

    /// @notice Withdraws assets from a vault, first using available balance and then borrowing if needed

    /// @dev This function first checks if there's an existing balance in the vault.
    /// @dev If there is, it withdraws the minimum of the requested amount and available balance.
    /// @dev If more assets are needed after withdrawal, it enables the controller and borrows the remaining amount.
    function withdrawAssets(address aave, IAaveLoopSwap.Params memory p, address debtToken, uint256 amount, address to)
        internal
    {      

        address asset = IAToken(debtToken).UNDERLYING_ASSET_ADDRESS();

        IAavePool(aave).borrow(asset, amount, 2, 0, p.aaveAccount);
        IERC20(asset).safeTransfer(to, amount);
    }

    /// @notice Deposits assets into a vault and automatically repays any outstanding debt
    /// @dev This function attempts to deposit assets into the specified vault.
    /// @dev If the deposit fails with E_ZeroShares error, it safely returns 0 (this happens with very small amounts).
    /// @dev After successful deposit, if the user has any outstanding controller-enabled debt, it attempts to repay it.
    /// @dev If all debt is repaid, the controller is automatically disabled to reduce gas costs in future operations.
    function depositAssets(address aave, IAaveLoopSwap.Params memory p, address debtToken) internal returns (uint256) {
        address asset = IAToken(debtToken).UNDERLYING_ASSET_ADDRESS();

        uint256 amount = IERC20(asset).balanceOf(address(this));
        if (amount == 0) return 0;

        uint256 feeAmount = amount * p.fee / 1e18;

        if (p.protocolFeeRecipient != address(0)) {
            uint256 protocolFeeAmount = feeAmount * p.protocolFee / 1e18;

            if (protocolFeeAmount != 0) {
                IERC20(asset).safeTransfer(p.protocolFeeRecipient, protocolFeeAmount);
                amount -= protocolFeeAmount;
                feeAmount -= protocolFeeAmount;
            }
        }

        IAavePool(aave).repay(asset, amount, 2, p.aaveAccount); // this is not actually euler account but no worries

        return amount - feeAmount;
    }

    function flashLoanAssets(address aave, IAaveLoopSwap.Params memory p, uint256 amount0Out, uint256 amount1Out, address to, bytes memory data) internal { 

        address[] memory assets = new address[](2);
        assets[0] = IAToken(p.debtToken0).UNDERLYING_ASSET_ADDRESS();
        assets[1] = IAToken(p.debtToken1).UNDERLYING_ASSET_ADDRESS();

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount0Out;
        amounts[1] = amount1Out;

        uint256[] memory interestRateModes = new uint256[](2);
        interestRateModes[0] = amount0Out == 0 ? 0 : 2;
        interestRateModes[1] = amount1Out == 0 ? 0 : 2;

        bytes memory flashloanData = abi.encode(amount0Out, amount1Out, to, data);
        IAavePool(aave).flashLoan(address(this), assets, amounts, interestRateModes, p.aaveAccount, flashloanData, 0);

        

    }
}
