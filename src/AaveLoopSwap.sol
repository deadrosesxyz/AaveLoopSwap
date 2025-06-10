// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;

import {IAaveLoopSwapCallee} from "./interfaces/IAaveLoopSwapCallee.sol";

import {IAaveLoopSwap} from "./interfaces/IAaveLoopSwap.sol";
import {UniswapHook} from "./UniswapHook.sol";
import "./Events.sol";
import {CtxLib} from "./libraries/CtxLib.sol";
import {FundsLib} from "./libraries/FundsLib.sol";
import {CurveLib} from "./libraries/CurveLib.sol";
import {QuoteLib} from "./libraries/QuoteLib.sol";

import {IAToken} from "./interfaces/IAToken.sol";
import {IAavePool} from "./interfaces/IAavePool.sol";
/*
    NOTE: THE FOLLOWING CODE HAS BEEN MADE TO WORK SPECIFICALLY WITH USDC/USDT.
    IT'S NOT SUITABLE FOR ANY OTHER TOKEN PAIRS. THE CODE ASSUMES THE TWO TOKENS HAVE THE SAME PRICE
    AND SAME DECIMAL PRECISION

*/

contract AaveLoopSwap is IAaveLoopSwap, UniswapHook {
    bytes32 public constant curve = bytes32("AaveLoopSwap v1");

    error Locked();
    error AlreadyActivated();
    error BadParam();
    error AmountTooBig();
    error AssetsOutOfOrderOrEqual();

    constructor(address _aave, address poolManager_) UniswapHook(poolManager_, _aave) {
        CtxLib.Storage storage s = CtxLib.getStorage();

        s.status = 2; // can only be used via delegatecall proxy
    }

    modifier nonReentrant() {
        CtxLib.Storage storage s = CtxLib.getStorage();

        require(s.status == 1, Locked());
        s.status = 2;
        _;
        s.status = 1;
    }

    modifier nonReentrantView() {
        CtxLib.Storage storage s = CtxLib.getStorage();
        require(s.status != 2, Locked());

        _;
    }

    /// @inheritdoc IAaveLoopSwap
    function activate(InitialState calldata initialState) external {
        CtxLib.Storage storage s = CtxLib.getStorage();
        Params memory p = CtxLib.getParams();

        require(s.status == 0, AlreadyActivated());
        s.status = 1;

        // Parameter validation

        require(p.fee < 1e18, BadParam());
        require(p.priceX > 0 && p.priceY > 0, BadParam());
        require(p.priceX <= 1e25 && p.priceY <= 1e25, BadParam());
        require(p.concentrationX <= 1e18 && p.concentrationY <= 1e18, BadParam());

        {
            address asset0Addr = IAToken(p.debtToken0).UNDERLYING_ASSET_ADDRESS();
            address asset1Addr = IAToken(p.debtToken1).UNDERLYING_ASSET_ADDRESS();
            require(asset0Addr < asset1Addr, AssetsOutOfOrderOrEqual());
            emit EulerSwapActivated(asset0Addr, asset1Addr);
        }

        // Initial state

        s.reserve0 = initialState.currReserve0;
        s.reserve1 = initialState.currReserve1;

        require(CurveLib.verify(p, s.reserve0, s.reserve1), CurveLib.CurveViolation());
        if (s.reserve0 != 0) require(!CurveLib.verify(p, s.reserve0 - 1, s.reserve1), CurveLib.CurveViolation());
        if (s.reserve1 != 0) require(!CurveLib.verify(p, s.reserve0, s.reserve1 - 1), CurveLib.CurveViolation());

        // Configure external contracts

        FundsLib.approveAsset(p.debtToken0, aave);
        FundsLib.approveAsset(p.debtToken1, aave);

        // Uniswap hooks

        if (address(poolManager) != address(0)) activateHook(p);
    }

    /// @inheritdoc IAaveLoopSwap
    function getParams() external pure returns (Params memory) {
        return CtxLib.getParams();
    }

    /// @inheritdoc IAaveLoopSwap
    function getAssets() external view returns (address asset0, address asset1) {
        Params memory p = CtxLib.getParams();

        asset0 = IAToken(p.debtToken0).UNDERLYING_ASSET_ADDRESS();
        asset1 = IAToken(p.debtToken1).UNDERLYING_ASSET_ADDRESS();
    }

    /// @inheritdoc IAaveLoopSwap
    function getReserves() external view nonReentrantView returns (uint112, uint112, uint32) {
        CtxLib.Storage storage s = CtxLib.getStorage();

        return (s.reserve0, s.reserve1, s.status);
    }

    /// @inheritdoc IAaveLoopSwap
    function computeQuote(address tokenIn, address tokenOut, uint256 amount, bool exactIn)
        external
        view
        nonReentrantView
        returns (uint256)
    {
        Params memory p = CtxLib.getParams();

        return QuoteLib.computeQuote(address(aave), p, QuoteLib.checkTokens(p, tokenIn, tokenOut), amount, exactIn);
    }

    /// @inheritdoc IAaveLoopSwap
    function getLimits(address tokenIn, address tokenOut) external view nonReentrantView returns (uint256, uint256) {
        Params memory p = CtxLib.getParams();

        return QuoteLib.calcLimits(p, QuoteLib.checkTokens(p, tokenIn, tokenOut));
    }

    /// @inheritdoc IAaveLoopSwap
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data)
        external
        nonReentrant
    {
        require(amount0Out <= type(uint112).max && amount1Out <= type(uint112).max, AmountTooBig());
        Params memory p = CtxLib.getParams();

        FundsLib.flashLoanAssets(aave, p, amount0Out, amount1Out, to, data);
    }

    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata data
    ) external returns (bool) {
        require(msg.sender == aave, "mba");
        require(initiator == address(this), "imt");

        CtxLib.Storage storage s = CtxLib.getStorage();
        Params memory p = CtxLib.getParams();

        (uint256 amount0Out, uint256 amount1Out, address to, bytes memory callbackData) = abi.decode(data, (uint256, uint256, address, bytes));

        if (callbackData.length > 0) IAaveLoopSwapCallee(to).aaveLoopSwapCall(address(0), amount0Out, amount1Out, callbackData);

        uint256 amount0In = FundsLib.depositAssets(address(aave), p, p.debtToken0);
        uint256 amount1In = FundsLib.depositAssets(address(aave), p, p.debtToken1);

        {
            uint256 newReserve0 = s.reserve0 + amount0In - amount0Out;
            uint256 newReserve1 = s.reserve1 + amount1In - amount1Out;

            require(CurveLib.verify(p, newReserve0, newReserve1), CurveLib.CurveViolation());

            s.reserve0 = uint112(newReserve0);
            s.reserve1 = uint112(newReserve1);
        }

        // here event would always have aave pool as first arg
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, s.reserve0, s.reserve1, to);

        return true;
    } 
}
