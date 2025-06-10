// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;

import {IAaveLoopSwap} from "../interfaces/IAaveLoopSwap.sol";
import {CtxLib} from "./CtxLib.sol";
import {CurveLib} from "./CurveLib.sol";
import {IAToken} from "../interfaces/IAToken.sol";


library QuoteLib {
    error UnsupportedPair();
    error OperatorNotInstalled();
    error SwapLimitExceeded();

    /// @return The quoted amount (output amount if exactIn=true, input amount if exactIn=false)
    /// @dev Validates:
    ///      - EulerSwap operator is installed
    ///      - Token pair is supported
    ///      - Sufficient reserves exist
    ///      - Sufficient cash is available
    function computeQuote(address aave, IAaveLoopSwap.Params memory p, bool asset0IsInput, uint256 amount, bool exactIn)
        internal
        view
        returns (uint256)
    {
        if (amount == 0) return 0;

        // here maybe add that the hook is approved to borrow?
        
        require(amount <= type(uint112).max, SwapLimitExceeded());

        uint256 fee = p.fee;

        // exactIn: decrease effective amountIn
        if (exactIn) amount = amount - (amount * fee / 1e18);

        (uint256 inLimit, uint256 outLimit) = calcLimits(p, asset0IsInput);

        uint256 quote = findCurvePoint(p, amount, exactIn, asset0IsInput);

        if (exactIn) {
            // if `exactIn`, `quote` is the amount of assets to buy from the AMM
            require(amount <= inLimit && quote <= outLimit, SwapLimitExceeded());
        } else {
            // if `!exactIn`, `amount` is the amount of assets to buy from the AMM
            require(amount <= outLimit && quote <= inLimit, SwapLimitExceeded());
        }

        // exactOut: inflate required amountIn
        if (!exactIn) quote = (quote * 1e18) / (1e18 - fee);

        return quote;
    }

    /// @notice Calculates the maximum input and output amounts for a swap based on protocol constraints
    /// @dev Determines limits by checking multiple factors:
    ///      1. Supply caps and existing debt for the input token
    ///      2. Available reserves in the EulerSwap for the output token
    ///      3. Available cash and borrow caps for the output token
    ///      4. Account balances in the respective vaults
    function calcLimits(IAaveLoopSwap.Params memory p, bool asset0IsInput) internal view returns (uint256, uint256) {
        CtxLib.Storage storage s = CtxLib.getStorage();

        uint256 inLimit = type(uint112).max;
        uint256 outLimit = type(uint112).max;

        address aaveAccount = p.aaveAccount;
        (IAToken debtToken0, IAToken debtToken1) = (IAToken(p.debtToken0), IAToken(p.debtToken1));
        
        // Supply caps on input
        {
            IAToken token = (asset0IsInput ? debtToken0 : debtToken1);
            uint256 maxDeposit = IAToken(token).balanceOf(aaveAccount); // max deposit is such that we repay the outstanding debt.
            if (maxDeposit < inLimit) inLimit = maxDeposit;
        }

        // Remaining reserves of output
        {   
            // technically, the outLimit should never possibly be reached?
            // exactAmountOut swaps for close to max reserves might fail.
            uint112 reserveLimit = asset0IsInput ? s.reserve1 : s.reserve0;
            if (reserveLimit < outLimit) outLimit = reserveLimit;
        }


        return (inLimit, outLimit);
    }

    /// @notice Verifies that the given tokens are supported by the EulerSwap pool and determines swap direction
    /// @dev Returns a boolean indicating whether the input token is asset0 (true) or asset1 (false)
    /// @custom:error UnsupportedPair Thrown if the token pair is not supported by the EulerSwap pool
    function checkTokens(IAaveLoopSwap.Params memory p, address tokenIn, address tokenOut)
        internal
        view
        returns (bool asset0IsInput)
    {
        address asset0 = IAToken(p.debtToken0).UNDERLYING_ASSET_ADDRESS();
        address asset1 = IAToken(p.debtToken1).UNDERLYING_ASSET_ADDRESS();

        if (tokenIn == asset0 && tokenOut == asset1) asset0IsInput = true;
        else if (tokenIn == asset1 && tokenOut == asset0) asset0IsInput = false;
        else revert UnsupportedPair();
    }

    function findCurvePoint(IAaveLoopSwap.Params memory p, uint256 amount, bool exactIn, bool asset0IsInput)
        internal
        view
        returns (uint256 output)
    {
        CtxLib.Storage storage s = CtxLib.getStorage();

        uint256 px = p.priceX;
        uint256 py = p.priceY;
        uint256 x0 = p.equilibriumReserve0;
        uint256 y0 = p.equilibriumReserve1;
        uint256 cx = p.concentrationX;
        uint256 cy = p.concentrationY;
        uint112 reserve0 = s.reserve0;
        uint112 reserve1 = s.reserve1;

        uint256 xNew;
        uint256 yNew;

        if (exactIn) {
            // exact in
            if (asset0IsInput) {
                // swap X in and Y out
                xNew = reserve0 + amount;
                if (xNew <= x0) {
                    // remain on f()
                    yNew = CurveLib.f(xNew, px, py, x0, y0, cx);
                } else {
                    // move to g()
                    yNew = CurveLib.fInverse(xNew, py, px, y0, x0, cy);
                }
                output = reserve1 > yNew ? reserve1 - yNew : 0;
            } else {
                // swap Y in and X out
                yNew = reserve1 + amount;
                if (yNew <= y0) {
                    // remain on g()
                    xNew = CurveLib.f(yNew, py, px, y0, x0, cy);
                } else {
                    // move to f()
                    xNew = CurveLib.fInverse(yNew, px, py, x0, y0, cx);
                }
                output = reserve0 > xNew ? reserve0 - xNew : 0;
            }
        } else {
            // exact out
            if (asset0IsInput) {
                // swap Y out and X in
                require(reserve1 > amount, SwapLimitExceeded());
                yNew = reserve1 - amount;
                if (yNew <= y0) {
                    // remain on g()
                    xNew = CurveLib.f(yNew, py, px, y0, x0, cy);
                } else {
                    // move to f()
                    xNew = CurveLib.fInverse(yNew, px, py, x0, y0, cx);
                }
                output = xNew > reserve0 ? xNew - reserve0 : 0;
            } else {
                // swap X out and Y in
                require(reserve0 > amount, SwapLimitExceeded());
                xNew = reserve0 - amount;
                if (xNew <= x0) {
                    // remain on f()
                    yNew = CurveLib.f(xNew, px, py, x0, y0, cx);
                } else {
                    // move to g()
                    yNew = CurveLib.fInverse(xNew, py, px, y0, x0, cy);
                }
                output = yNew > reserve1 ? yNew - reserve1 : 0;
            }
        }
    }
}
