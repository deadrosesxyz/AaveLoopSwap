// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {PoolKey} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {
    BeforeSwapDelta, toBeforeSwapDelta, BeforeSwapDeltaLibrary
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {IEVault} from "evk/EVault/IEVault.sol";

import {IAaveLoopSwap} from "./interfaces/IAaveLoopSwap.sol";
import "./Events.sol";
import {CtxLib} from "./libraries/CtxLib.sol";
import {QuoteLib} from "./libraries/QuoteLib.sol";
import {CurveLib} from "./libraries/CurveLib.sol";
import {FundsLib} from "./libraries/FundsLib.sol";
import {IAToken} from "./interfaces/IAToken.sol";


contract UniswapHook is BaseHook {
    using SafeCast for uint256;

    address internal immutable aave;

    PoolKey internal _poolKey;

    error LockedHook();

    constructor(address _poolManager, address _aave) BaseHook(IPoolManager(_poolManager)) {
        aave = _aave;
    }

    function activateHook(IAaveLoopSwap.Params memory p) internal {
        Hooks.validateHookPermissions(this, getHookPermissions());

        address asset0Addr = IAToken(p.debtToken0).UNDERLYING_ASSET_ADDRESS();
        address asset1Addr = IAToken(p.debtToken1).UNDERLYING_ASSET_ADDRESS();

        // convert fee in WAD to pips. 0.003e18 / 1e12 = 3000 = 0.30%
        uint24 fee = uint24(p.fee / 1e12);

        _poolKey = PoolKey({
            currency0: Currency.wrap(asset0Addr),
            currency1: Currency.wrap(asset1Addr),
            fee: fee,
            tickSpacing: 1, // hard-coded tick spacing, as its unused
            hooks: IHooks(address(this))
        });

        // create the pool on v4, using starting price as sqrtPrice(1/1) * Q96
        poolManager.initialize(_poolKey, 79228162514264337593543950336);
    }

    /// @dev Helper function to return the poolKey as its struct type
    function poolKey() external view returns (PoolKey memory) {
        return _poolKey;
    }

    /// @dev Prevent hook address validation in constructor, which is not needed
    /// because hook instances are proxies. Instead, the address is validated
    /// in activateHook().
    function validateHookAddress(BaseHook _this) internal pure override {}

    modifier nonReentrantHook() {
        {
            CtxLib.Storage storage s = CtxLib.getStorage();
            require(s.status == 1, LockedHook());
            s.status = 2;
        }

        _;

        {
            CtxLib.Storage storage s = CtxLib.getStorage();
            s.status = 1;
        }
    }

    function _beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        internal
        override
        nonReentrantHook
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        IAaveLoopSwap.Params memory p = CtxLib.getParams();

        uint256 amountInWithoutFee;
        uint256 amountOut;
        BeforeSwapDelta returnDelta;

        {
            uint256 amountIn;
            bool isExactInput = params.amountSpecified < 0;
            if (isExactInput) {
                amountIn = uint256(-params.amountSpecified);
                amountOut = QuoteLib.computeQuote(aave, p, params.zeroForOne, amountIn, true);
            } else {
                amountOut = uint256(params.amountSpecified);
                amountIn = QuoteLib.computeQuote(aave, p, params.zeroForOne, amountOut, false);
            }

            // return the delta to the PoolManager, so it can process the accounting
            // exact input:
            //   specifiedDelta = positive, to offset the input token taken by the hook (negative delta)
            //   unspecifiedDelta = negative, to offset the credit of the output token paid by the hook (positive delta)
            // exact output:
            //   specifiedDelta = negative, to offset the output token paid by the hook (positive delta)
            //   unspecifiedDelta = positive, to offset the input token taken by the hook (negative delta)

            
            returnDelta = isExactInput
                ? toBeforeSwapDelta(amountIn.toInt128(), -(amountOut.toInt128()))
                : toBeforeSwapDelta(-(amountOut.toInt128()), amountIn.toInt128());

            // take the input token, from the PoolManager to the Euler vault
            // the debt will be paid by the swapper via the swap router
            poolManager.take(params.zeroForOne ? key.currency0 : key.currency1, address(this), amountIn);
            amountInWithoutFee = FundsLib.depositAssets(aave, p, params.zeroForOne ? p.debtToken0 : p.debtToken1);

            // pay the output token, to the PoolManager from an Euler vault
            // the credit will be forwarded to the swap router, which then forwards it to the swapper
            poolManager.sync(params.zeroForOne ? key.currency1 : key.currency0);
            FundsLib.withdrawAssets(aave, p, params.zeroForOne ? p.debtToken1 : p.debtToken0, amountOut, address(poolManager));
            poolManager.settle();
        }

        {
            CtxLib.Storage storage s = CtxLib.getStorage();

            uint256 newReserve0 = params.zeroForOne ? (s.reserve0 + amountInWithoutFee) : (s.reserve0 - amountOut);
            uint256 newReserve1 = !params.zeroForOne ? (s.reserve1 + amountInWithoutFee) : (s.reserve1 - amountOut);

            require(CurveLib.verify(p, newReserve0, newReserve1), CurveLib.CurveViolation());

            s.reserve0 = uint112(newReserve0);
            s.reserve1 = uint112(newReserve1);

            if (params.zeroForOne) {
                emit Swap(sender, amountInWithoutFee, 0, 0, amountOut, s.reserve0, s.reserve1, msg.sender);
            } else {
                emit Swap(sender, 0, amountInWithoutFee, amountOut, 0, s.reserve0, s.reserve1, msg.sender);
            }
        }

        return (BaseHook.beforeSwap.selector, returnDelta, 0);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        /**
         * @dev Hook Permissions without overrides:
         * - beforeInitialize, beforeDoate, beforeAddLiquidity
         * We use BaseHook's original reverts to *intentionally* revert
         *
         * beforeInitialize: the hook reverts for initializations NOT going through EulerSwap.activateHook()
         * we want to prevent users from initializing other pairs with the same hook address
         *
         * beforeDonate: because the hook does not support native concentrated liquidity, any
         * donations are permanently irrecoverable. The hook reverts on beforeDonate to prevent accidental misusage
         *
         * beforeAddLiquidity: the hook reverts to prevent v3-CLAMM positions
         * because the hook is a "custom curve", any concentrated liquidity position sits idle and entirely unused
         * to protect users from accidentally creating non-productive positions, the hook reverts on beforeAddLiquidity
         */
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: true,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
