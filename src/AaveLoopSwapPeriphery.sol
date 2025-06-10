// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;

import {SafeERC20, IERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

import {IAaveLoopSwapPeriphery} from "./interfaces/IAaveLoopSwapPeriphery.sol";
import {IAaveLoopSwap} from "./interfaces/IAaveLoopSwap.sol";

contract AaveLoopSwapPeriphery is IAaveLoopSwapPeriphery {
    using SafeERC20 for IERC20;

    error AmountOutLessThanMin();
    error AmountInMoreThanMax();
    error DeadlineExpired();

    /// @inheritdoc IAaveLoopSwapPeriphery
    function swapExactIn(
        address eulerSwap,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address receiver,
        uint256 amountOutMin,
        uint256 deadline
    ) external {
        require(deadline == 0 || deadline >= block.timestamp, DeadlineExpired());

        uint256 amountOut = IAaveLoopSwap(eulerSwap).computeQuote(tokenIn, tokenOut, amountIn, true);

        require(amountOut >= amountOutMin, AmountOutLessThanMin());

        swap(IAaveLoopSwap(eulerSwap), tokenIn, tokenOut, amountIn, amountOut, receiver);
    }

    /// @inheritdoc IAaveLoopSwapPeriphery
    function swapExactOut(
        address eulerSwap,
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        address receiver,
        uint256 amountInMax,
        uint256 deadline
    ) external {
        require(deadline == 0 || deadline >= block.timestamp, DeadlineExpired());

        uint256 amountIn = IAaveLoopSwap(eulerSwap).computeQuote(tokenIn, tokenOut, amountOut, false);

        require(amountIn <= amountInMax, AmountInMoreThanMax());

        swap(IAaveLoopSwap(eulerSwap), tokenIn, tokenOut, amountIn, amountOut, receiver);
    }

    /// @inheritdoc IAaveLoopSwapPeriphery
    function quoteExactInput(address eulerSwap, address tokenIn, address tokenOut, uint256 amountIn)
        external
        view
        returns (uint256)
    {
        return IAaveLoopSwap(eulerSwap).computeQuote(tokenIn, tokenOut, amountIn, true);
    }

    /// @inheritdoc IAaveLoopSwapPeriphery
    function quoteExactOutput(address eulerSwap, address tokenIn, address tokenOut, uint256 amountOut)
        external
        view
        returns (uint256)
    {
        return IAaveLoopSwap(eulerSwap).computeQuote(tokenIn, tokenOut, amountOut, false);
    }

    /// @inheritdoc IAaveLoopSwapPeriphery
    function getLimits(address eulerSwap, address tokenIn, address tokenOut) external view returns (uint256, uint256) {
        return IAaveLoopSwap(eulerSwap).getLimits(tokenIn, tokenOut);
    }

    /// @dev Internal function to execute a token swap through EulerSwap
    /// @param eulerSwap The EulerSwap contract address to execute the swap through
    /// @param tokenIn The address of the input token being swapped
    /// @param tokenOut The address of the output token being received
    /// @param amountIn The amount of input tokens to swap
    /// @param amountOut The amount of output tokens to receive
    /// @param receiver The address that should receive the swap output
    function swap(
        IAaveLoopSwap eulerSwap,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address receiver
    ) internal {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(eulerSwap), amountIn);

        bool isAsset0In = tokenIn < tokenOut;
        (isAsset0In) ? eulerSwap.swap(0, amountOut, receiver, "") : eulerSwap.swap(amountOut, 0, receiver, "");
    }
}
