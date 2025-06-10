// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {EVaultTestBase, TestERC20, IRMTestDefault} from "evk-test/unit/evault/EVaultTestBase.t.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import {IAaveLoopSwap, AaveLoopSwap} from "../src/AaveLoopSwap.sol";
import {AaveLoopSwapFactory} from "../src/AaveLoopSwapFactory.sol";
import {IAavePool} from "../src/interfaces/IAavePool.sol";
import {AaveLoopSwapPeriphery} from "../src/AaveLoopSwapPeriphery.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
// import {HookMiner} from "./utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {MetaProxyDeployer} from "../src/utils/MetaProxyDeployer.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {IAToken} from "../src/interfaces/IAToken.sol";
import {HookMiner} from "./HookMiner.t.sol";


contract AaveLoopSwapTestBase is EVaultTestBase {
    uint256 public constant MAX_QUOTE_ERROR = 2;
    address aave = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    IERC20 usdc = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 usdt = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);

    address pt_susde = 0x3b3fB9C57858EF816833dC91565EFcd85D96f634;
    // address poolManager = 0x000000000004444c5dc75cB358380D2e3dE08A90;


    address public depositor = makeAddr("depositor");
    address public holder = makeAddr("holder");
    address public recipient = makeAddr("recipient");
    address public anyone = makeAddr("anyone");

    TestERC20 assetTST3;
    IEVault public eTST3;

    address public aaveLoopSwapImpl;
    AaveLoopSwapFactory public aaveLoopSwapFactory;
    AaveLoopSwapPeriphery public periphery;

    uint256 currSalt = 0;
    address installedOperator;


    function deployAaveLoopSwap(address poolManager_) public {
        aaveLoopSwapImpl = address(new AaveLoopSwap(address(aave), poolManager_));
        aaveLoopSwapFactory =
            new AaveLoopSwapFactory(address(aave), address(factory), aaveLoopSwapImpl, address(this), address(this));
        periphery = new AaveLoopSwapPeriphery();
    }


    function setUp() public virtual override {
        super.setUp();

        deployAaveLoopSwap(address(0)); // Default is no poolManager

        vm.startPrank(depositor);
        deal(pt_susde, depositor, 1_100_000e18);
        IERC20(pt_susde).approve(aave, type(uint256).max);

        IAavePool(aave).supply(pt_susde, 1_100_000e18, depositor, 0);
        IAavePool(aave).setUserEMode(8);
        IAavePool(aave).borrow(address(usdc), 450_000e6, 2, 0, depositor);
        IAavePool(aave).borrow(address(usdt), 450_000e6, 2, 0, depositor);

        uint256 px = 1000000;
        uint256 py = 1000000;
        uint256 cx = 999000000000000100;
        uint256 cy = 999000000000000100;
        
        createAaveLoopSwap(450_000e6, 450_000e6, 10000000000000, px, py, cx, cy);

    }

    function testBasic() public virtual{
        uint256 px = 1000000;
        uint256 py = 1000000;
        uint256 cx = 999000000000000100;
        uint256 cy = 999000000000000100;
        
        AaveLoopSwap pool = createAaveLoopSwap(450_000e6, 450_000e6, 10000000000000, px, py, cx, cy);

        address user = address(1337);
        deal(address(usdc), user, 100e6);

        vm.startPrank(user);
        IERC20(usdc).approve(address(periphery), 100e6); 

        periphery.swapExactIn(address(pool), address(usdc), address(usdt), 100e6, user, 99e6, block.timestamp);

    }


    function createAaveLoopSwap(
        uint112 reserve0,
        uint112 reserve1,
        uint256 fee,
        uint256 px,
        uint256 py,
        uint256 cx,
        uint256 cy
    ) internal returns (AaveLoopSwap) {
        return createAaveLoopSwapFull(reserve0, reserve1, fee, px, py, cx, cy, 0, address(0));
    }

    function createAaveLoopSwapHook(
        uint112 reserve0,
        uint112 reserve1,
        uint256 fee,
        uint256 px,
        uint256 py,
        uint256 cx,
        uint256 cy
    ) internal returns (AaveLoopSwap) {
        return createAaveLoopSwapHookFull(reserve0, reserve1, fee, px, py, cx, cy, 0, address(0));
    }


    function createAaveLoopSwapFull(
        uint112 reserve0,
        uint112 reserve1,
        uint256 fee,
        uint256 px,
        uint256 py,
        uint256 cx,
        uint256 cy,
        uint256 protocolFee,
        address protocolFeeRecipient
    ) internal returns (AaveLoopSwap) {

        IAaveLoopSwap.Params memory params =
            getAaveLoopSwapParams(reserve0, reserve1, px, py, cx, cy, fee, protocolFee, protocolFeeRecipient);
        IAaveLoopSwap.InitialState memory initialState =
            IAaveLoopSwap.InitialState({currReserve0: reserve0, currReserve1: reserve1});

        bytes32 salt = bytes32(currSalt++);

        address predictedAddr = aaveLoopSwapFactory.computePoolAddress(params, salt);

        vm.startPrank(depositor);
        IAToken(params.debtToken0).approveDelegation(predictedAddr, type(uint256).max);
        IAToken(params.debtToken1).approveDelegation(predictedAddr, type(uint256).max);


        vm.startPrank(depositor);
        AaveLoopSwap aaveLoopSwap = AaveLoopSwap(aaveLoopSwapFactory.deployPool(params, initialState, salt));

        return aaveLoopSwap;
    }


    function createAaveLoopSwapHookFull(
        uint112 reserve0,
        uint112 reserve1,
        uint256 fee,
        uint256 px,
        uint256 py,
        uint256 cx,
        uint256 cy,
        uint256 protocolFee,
        address protocolFeeRecipient
    ) internal returns (AaveLoopSwap) {

        IAaveLoopSwap.Params memory params =
            getAaveLoopSwapParams(reserve0, reserve1, px, py, cx, cy, fee, protocolFee, protocolFeeRecipient);
        IAaveLoopSwap.InitialState memory initialState =
            IAaveLoopSwap.InitialState({currReserve0: reserve0, currReserve1: reserve1});

        bytes memory creationCode = MetaProxyDeployer.creationCodeMetaProxy(aaveLoopSwapImpl, abi.encode(params));
        (address predictedAddr, bytes32 salt) = HookMiner.find(
            address(aaveLoopSwapFactory),
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                    | Hooks.BEFORE_DONATE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            ),
            creationCode
        );

        vm.startPrank(depositor);
        IAToken(params.debtToken0).approveDelegation(predictedAddr, type(uint256).max);
        IAToken(params.debtToken1).approveDelegation(predictedAddr, type(uint256).max);


        vm.startPrank(depositor);
        AaveLoopSwap aaveLoopSwap = AaveLoopSwap(aaveLoopSwapFactory.deployPool(params, initialState, salt));

        return aaveLoopSwap;
    }
    

    function getAaveLoopSwapParams(
        uint112 reserve0,
        uint112 reserve1,
        uint256 px,
        uint256 py,
        uint256 cx,
        uint256 cy,
        uint256 fee,
        uint256 protocolFee,
        address protocolFeeRecipient
    ) internal view returns (AaveLoopSwap.Params memory) {
        return IAaveLoopSwap.Params({
            debtToken0: IAavePool(aave).getReserveVariableDebtToken(address(usdc)),
            debtToken1: IAavePool(aave).getReserveVariableDebtToken(address(usdt)),
            aaveAccount: depositor,
            equilibriumReserve0: reserve0,
            equilibriumReserve1: reserve1,
            priceX: px,
            priceY: py,
            concentrationX: cx,
            concentrationY: cy,
            fee: fee,
            protocolFee: protocolFee,
            protocolFeeRecipient: protocolFeeRecipient
        });
    }



}