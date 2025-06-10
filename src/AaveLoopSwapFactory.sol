// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;

import {EnumerableSet} from "openzeppelin-contracts/utils/structs/EnumerableSet.sol";

import {IAaveLoopSwapFactory, IAaveLoopSwap} from "./interfaces/IAaveLoopSwapFactory.sol";
import {GenericFactory} from "evk/GenericFactory/GenericFactory.sol";

import {AaveLoopSwap} from "./AaveLoopSwap.sol";
import {ProtocolFee} from "./utils/ProtocolFee.sol";
import {MetaProxyDeployer} from "./utils/MetaProxyDeployer.sol";

/// @title AaveLoopSwapFactory contract
/// @custom:security-contact security@euler.xyz
/// @author Euler Labs (https://www.eulerlabs.com/)
contract AaveLoopSwapFactory is IAaveLoopSwapFactory, ProtocolFee {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @dev Vaults must be deployed by this factory
    address public immutable evkFactory;
    /// @dev The AaveLoopSwap code instance that will be proxied to
    address public immutable AaveLoopSwapImpl;

    address public immutable aave;

    /// @dev Mapping from euler account to pool, if installed
    mapping(address aaveAccount => address) internal installedPools;
    /// @dev Set of all pool addresses
    EnumerableSet.AddressSet internal allPools;
    /// @dev Mapping from sorted pair of underlyings to set of pools
    mapping(address asset0 => mapping(address asset1 => EnumerableSet.AddressSet)) internal poolMap;

    event PoolDeployed(address indexed asset0, address indexed asset1, address indexed aaveAccount, address pool);
    event PoolConfig(address indexed pool, IAaveLoopSwap.Params params, IAaveLoopSwap.InitialState initialState);
    event PoolUninstalled(address indexed asset0, address indexed asset1, address indexed aaveAccount, address pool);

    error InvalidQuery();
    error Unauthorized();
    error OldOperatorStillInstalled();
    error OperatorNotInstalled();
    error InvalidVaultImplementation();
    error SliceOutOfBounds();
    error InvalidProtocolFee();

    constructor(
        address _aave,
        address evkFactory_,
        address AaveLoopSwapImpl_,
        address feeOwner_,
        address feeRecipientSetter_
    ) ProtocolFee(feeOwner_, feeRecipientSetter_) {
        aave = _aave;
        evkFactory = evkFactory_;
        AaveLoopSwapImpl = AaveLoopSwapImpl_;
    }

    /// @inheritdoc IAaveLoopSwapFactory
    function deployPool(IAaveLoopSwap.Params memory params, IAaveLoopSwap.InitialState memory initialState, bytes32 salt)
        external
        returns (address)
    {
        // require(_msg.sender == params.aaveAccount, Unauthorized());

        require(
            params.protocolFee == protocolFee && params.protocolFeeRecipient == protocolFeeRecipient,
            InvalidProtocolFee()
        );

        // uninstall(params.aaveAccount);

        AaveLoopSwap pool = AaveLoopSwap(MetaProxyDeployer.deployMetaProxy(AaveLoopSwapImpl, abi.encode(params), salt));

        // updateaaveAccountState(params.aaveAccount, address(pool));

        pool.activate(initialState);

        (address asset0, address asset1) = pool.getAssets();
        emit PoolDeployed(asset0, asset1, params.aaveAccount, address(pool));
        emit PoolConfig(address(pool), params, initialState);

        return address(pool);
    }

    // /// @inheritdoc IAaveLoopSwapFactory
    // function uninstallPool() external {
    //     uninstall(msg.sender);
    // }

    /// @inheritdoc IAaveLoopSwapFactory
    function computePoolAddress(IAaveLoopSwap.Params memory poolParams, bytes32 salt) external view returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            address(this),
                            salt,
                            keccak256(MetaProxyDeployer.creationCodeMetaProxy(AaveLoopSwapImpl, abi.encode(poolParams)))
                        )
                    )
                )
            )
        );
    }

    // /// @inheritdoc IAaveLoopSwapFactory
    // function poolByaaveAccount(address aaveAccount) external view returns (address) {
    //     return installedPools[aaveAccount];
    // }

    /// @inheritdoc IAaveLoopSwapFactory
    function poolsLength() external view returns (uint256) {
        return allPools.length();
    }

    /// @inheritdoc IAaveLoopSwapFactory
    function poolsSlice(uint256 start, uint256 end) external view returns (address[] memory) {
        return getSlice(allPools, start, end);
    }

    /// @inheritdoc IAaveLoopSwapFactory
    function pools() external view returns (address[] memory) {
        return allPools.values();
    }

    /// @inheritdoc IAaveLoopSwapFactory
    function poolsByPairLength(address asset0, address asset1) external view returns (uint256) {
        return poolMap[asset0][asset1].length();
    }

    /// @inheritdoc IAaveLoopSwapFactory
    function poolsByPairSlice(address asset0, address asset1, uint256 start, uint256 end)
        external
        view
        returns (address[] memory)
    {
        return getSlice(poolMap[asset0][asset1], start, end);
    }

    /// @inheritdoc IAaveLoopSwapFactory
    function poolsByPair(address asset0, address asset1) external view returns (address[] memory) {
        return poolMap[asset0][asset1].values();
    }

    /// @notice Validates operator authorization for euler account and update the relevant aaveAccountState.
    /// @param aaveAccount The address of the euler account.
    /// @param newOperator The address of the new pool.
    // function updateaaveAccountState(address aaveAccount, address newOperator) internal {
    //     require(evc.isAccountOperatorAuthorized(aaveAccount, newOperator), OperatorNotInstalled());

    //     (address asset0, address asset1) = IAaveLoopSwap(newOperator).getAssets();

    //     installedPools[aaveAccount] = newOperator;

    //     allPools.add(newOperator);
    //     poolMap[asset0][asset1].add(newOperator);
    // }

    /// @notice Uninstalls the pool associated with the given Euler account
    /// @dev This function removes the pool from the factory's tracking and emits a PoolUninstalled event
    /// @dev The function checks if the operator is still installed and reverts if it is
    /// @dev If no pool exists for the account, the function returns without any action
    /// @param aaveAccount The address of the Euler account whose pool should be uninstalled
    // function uninstall(address aaveAccount) internal {
    //     address pool = installedPools[aaveAccount];

    //     if (pool == address(0)) return;

    //     require(!evc.isAccountOperatorAuthorized(aaveAccount, pool), OldOperatorStillInstalled());

    //     (address asset0, address asset1) = IAaveLoopSwap(pool).getAssets();

    //     allPools.remove(pool);
    //     poolMap[asset0][asset1].remove(pool);

    //     delete installedPools[aaveAccount];

    //     emit PoolUninstalled(asset0, asset1, aaveAccount, pool);
    // }

    /// @notice Returns a slice of an array of addresses
    /// @dev Creates a new memory array containing elements from start to end index
    ///      If end is type(uint256).max, it will return all elements from start to the end of the array
    /// @param arr The storage array to slice
    /// @param start The starting index of the slice (inclusive)
    /// @param end The ending index of the slice (exclusive)
    /// @return A new memory array containing the requested slice of addresses
    function getSlice(EnumerableSet.AddressSet storage arr, uint256 start, uint256 end)
        internal
        view
        returns (address[] memory)
    {
        uint256 length = arr.length();
        if (end == type(uint256).max) end = length;
        if (end < start || end > length) revert SliceOutOfBounds();

        address[] memory slice = new address[](end - start);
        for (uint256 i; i < end - start; ++i) {
            slice[i] = arr.at(start + i);
        }

        return slice;
    }

    function _AaveLoopSwapImpl() internal view returns (address) {
        return AaveLoopSwapImpl;
    }
}
