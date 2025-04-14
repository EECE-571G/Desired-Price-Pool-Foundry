// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";
import {IPositionDescriptor} from "v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";

import {Arrays} from "@openzeppelin/contracts/utils/Arrays.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {DPPConstants} from "../src/libraries/DPPConstants.sol";
import {DesiredPricePool} from "../src/DesiredPricePool.sol";
import {DeployPermit2} from "../test/utils/forks/DeployPermit2.sol";
import {EasyPosm} from "../test/utils/EasyPosm.sol";

/// @notice Forge script for deploying v4 & hooks to **anvil**
contract DesiredPricePoolScript is Script, DeployPermit2 {
    using EasyPosm for IPositionManager;

    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);
    IPoolManager manager;
    IPositionManager posm;
    PoolModifyLiquidityTest lpRouter;
    PoolSwapTest swapRouter;

    function setUp() public {}

    function run() public {
        vm.broadcast();
        manager = deployPoolManager();

        bytes memory constructorArgs = abi.encode(manager, posm, msg.sender);
        // Mine a salt that will produce a hook address with the correct permissions
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER, DPPConstants.PERMISSION_FLAGS, type(DesiredPricePool).creationCode, constructorArgs
        );

        // ----------------------------- //
        // Deploy the hook using CREATE2 //
        // ----------------------------- //
        vm.broadcast();
        DesiredPricePool dpp = new DesiredPricePool{salt: salt}(manager, posm, msg.sender);
        require(address(dpp) == hookAddress, "DesiredPricePoolScript: hook address mismatch");

        // Additional helpers for interacting with the pool
        vm.startBroadcast();
        posm = deployPosm(manager);
        (lpRouter, swapRouter,) = deployRouters(manager);
        vm.stopBroadcast();

        // Log the addresses of the deployed contracts
        console.log("DesiredPricePool deployed at:", address(dpp));
        console.log("PoolManager deployed at:", address(manager));
        console.log("PositionManager deployed at:", address(posm));

        // Test the lifecycle (create pool, add liquidity)
        vm.startBroadcast();
        testLifecycle(dpp);
        vm.stopBroadcast();
    }

    // -----------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------
    function deployPoolManager() internal returns (IPoolManager) {
        return IPoolManager(address(new PoolManager(address(0))));
    }

    function deployRouters(IPoolManager _manager)
        internal
        returns (PoolModifyLiquidityTest _lpRouter, PoolSwapTest _swapRouter, PoolDonateTest _donateRouter)
    {
        _lpRouter = new PoolModifyLiquidityTest(_manager);
        _swapRouter = new PoolSwapTest(_manager);
        _donateRouter = new PoolDonateTest(_manager);
    }

    function deployPosm(IPoolManager poolManager) public returns (IPositionManager) {
        anvilPermit2();
        return IPositionManager(
            new PositionManager(poolManager, permit2, 300_000, IPositionDescriptor(address(0)), IWETH9(address(0)))
        );
    }

    function approvePosmCurrency(IPositionManager _posm, Currency currency) internal {
        // Because POSM uses permit2, we must execute 2 permits/approvals.
        // 1. First, the caller must approve permit2 on the token.
        IERC20(Currency.unwrap(currency)).approve(address(permit2), type(uint256).max);
        // 2. Then, the caller must approve POSM as a spender of permit2
        permit2.approve(Currency.unwrap(currency), address(_posm), type(uint160).max, type(uint48).max);
    }

    function deployTokens(uint256 count) internal returns (MockERC20[] memory tokens) {
        require(count <= 26, "Too many tokens requested");
        tokens = new MockERC20[](count);
        address[] memory tokenAddresses = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            bytes memory letter = new bytes(1);
            letter[0] = bytes1(uint8(65 + i));
            string memory name = string(abi.encodePacked("Mock", letter));
            string memory symbol = string(letter);
            tokens[i] = new MockERC20(name, symbol, 18);
            tokenAddresses[i] = address(tokens[i]);
        }

        tokenAddresses = Arrays.sort(tokenAddresses);
        for (uint256 i = 0; i < count; i++) {
            tokens[i] = MockERC20(tokenAddresses[i]);
        }

        // Log the addresses of the deployed tokens
        for (uint256 i = 0; i < count; i++) {
            console.log("Token %s (%s) deployed at: %s", i, tokens[i].name(), tokenAddresses[i]);
        }
    }

    function testLifecycle(DesiredPricePool dpp) internal {
        uint256 tokenCount = 3;
        MockERC20[] memory tokens = deployTokens(tokenCount);

        // Mint and approve the tokens
        for (uint256 i = 0; i < tokenCount; i++) {
            tokens[i].mint(msg.sender, 100_000 ether);
            tokens[i].approve(address(lpRouter), type(uint256).max);
            tokens[i].approve(address(swapRouter), type(uint256).max);
            approvePosmCurrency(posm, Currency.wrap(address(tokens[i])));
        }

        // Initialize pools and add full-range liquidity
        int24 tickSpacing = 64;
        int24 tickLower = TickMath.minUsableTick(tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(tickSpacing);
        for (uint256 i = 0; i < tokenCount - 1; i++) {
            Currency first = Currency.wrap(address(tokens[i]));
            for (uint256 j = i + 1; j < tokenCount; j++) {
                PoolKey memory key =
                    dpp.createPool(first, Currency.wrap(address(tokens[j])), tickSpacing, Constants.SQRT_PRICE_1_1, 0);
                _exampleAddLiquidity(key, tickLower, tickUpper);
            }
        }
    }

    function _exampleAddLiquidity(PoolKey memory poolKey, int24 tickLower, int24 tickUpper) internal {
        // provisions full-range liquidity twice. Two different periphery contracts used for example purposes.
        IPoolManager.ModifyLiquidityParams memory liqParams =
            IPoolManager.ModifyLiquidityParams(tickLower, tickUpper, 100 ether, 0);
        lpRouter.modifyLiquidity(poolKey, liqParams, "");

        posm.mint(poolKey, tickLower, tickUpper, 100e18, 10_000e18, 10_000e18, msg.sender, block.timestamp + 300, "");
    }
}
