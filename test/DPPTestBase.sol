// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

import {DesiredPricePool} from "../src/DesiredPricePool.sol";
import {DPPConstants} from "../src/libraries/DPPConstants.sol";
import {Fixtures} from "./utils/Fixtures.sol";

abstract contract DPPTestBase is Test, Fixtures {
    DesiredPricePool dpp;
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

        // Create the pool
        key = dpp.createPool(currency0, currency1, 64, SQRT_PRICE_1_1, 0);
        poolId = key.toId();
    }
}
