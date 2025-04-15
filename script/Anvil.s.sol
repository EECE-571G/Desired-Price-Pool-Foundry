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

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Arrays} from "@openzeppelin/contracts/utils/Arrays.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IGovernanceToken} from "../src/interfaces/IGovernanceToken.sol";
import {DPPConstants} from "../src/libraries/DPPConstants.sol";
import {DesiredPricePool} from "../src/DesiredPricePool.sol";
import {DesiredPricePoolHelper} from "../src/DesiredPricePoolHelper.sol";
import {DeployPermit2} from "../test/utils/forks/DeployPermit2.sol";

/// @notice Forge script for deploying v4 & hooks to **anvil**
contract DesiredPricePoolScript is Script, DeployPermit2 {
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);
    IPoolManager manager;
    IPositionManager posm;
    DesiredPricePoolHelper dppHelper;

    function setUp() public {}

    function run() public {
        // Deploy PoolManager and PositionManager
        vm.startBroadcast();
        manager = deployPoolManager();
        posm = deployPosm(manager);
        vm.stopBroadcast();

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
        dppHelper = new DesiredPricePoolHelper(dpp);
        IGovernanceToken govToken = dpp.governanceToken();

        // Log the addresses of the deployed contracts
        console.log("PoolManager deployed at:", address(manager));
        console.log("PositionManager deployed at:", address(posm));
        console.log("DesiredPricePool deployed at:", address(dpp));
        console.log("GovernanceToken deployed at:", address(govToken));
        console.log("DesiredPricePoolHelper deployed at:", address(dppHelper));

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
            tokens[i].approve(address(dppHelper), type(uint256).max);
        }
        IERC721(address(posm)).setApprovalForAll(address(dppHelper), true);

        // Initialize pools and add full-range liquidity
        int24 tickSpacing = 64;
        int24 tickLower = TickMath.minUsableTick(tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(tickSpacing);
        for (uint256 i = 0; i < tokenCount - 1; i++) {
            Currency first = Currency.wrap(address(tokens[i]));
            for (uint256 j = i + 1; j < tokenCount; j++) {
                PoolKey memory key =
                    dpp.createPool(first, Currency.wrap(address(tokens[j])), tickSpacing, Constants.SQRT_PRICE_1_1, 0);
                dppHelper.mint(key, tickLower, tickUpper, 100 ether);
            }
        }
    }
}
