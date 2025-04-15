// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";

import {PositionInfo, PositionInfoLibrary} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {DesiredPricePool} from "../src/DesiredPricePool.sol";
import {DesiredPricePoolHelper} from "../src/DesiredPricePoolHelper.sol";
import {DPPConstants} from "../src/libraries/DPPConstants.sol";
import {Fixtures} from "./utils/Fixtures.sol";

abstract contract DPPTestBase is Test, Fixtures {
    using CurrencyLibrary for Currency;
    using PositionInfoLibrary for PositionInfo;
    using StateLibrary for IPoolManager;

    DesiredPricePool dpp;
    DesiredPricePoolHelper dppHelper;
    PoolId poolId;

    function setUp() public virtual {
        // creates the pool manager, utility routers, and test tokens
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        deployAndApprovePosm(manager);

        // Deploy the hook to an address with the correct flags
        address flags = address(DPPConstants.PERMISSION_FLAGS ^ (0x4444 << 144)); // Namespace the hook to avoid collisions
        bytes memory constructorArgs = abi.encode(manager, posm, address(this));
        deployCodeTo("DesiredPricePool.sol:DesiredPricePool", constructorArgs, flags);
        dpp = DesiredPricePool(flags);

        // Deploy and approve the helper
        dppHelper = new DesiredPricePoolHelper(dpp);
        IERC20(Currency.unwrap(currency0)).approve(address(dppHelper), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(dppHelper), type(uint256).max);
        IERC721(address(posm)).setApprovalForAll(address(dppHelper), true);

        // Create the pool
        key = dpp.createPool(currency0, currency1, 64, SQRT_PRICE_1_1, 0);
        poolId = key.toId();
    }
}
