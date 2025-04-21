# Desired Price Pool (DPP) for Uniswap V4

This project implements a custom Uniswap V4 hook system designed to incentivize liquidity providers (LPs) to concentrate liquidity around a *desired price* determined by governance, rather than solely around the current market price. It achieves this through a combination of a governance mechanism, a custom reward system, and Uniswap V4 hooks.

**Core Concepts:**

1.  **Desired Price:** A target price for a pool, determined through a periodic voting process using a dedicated governance token.
2.  **Incentivized Liquidity:** LPs are rewarded based on how close their liquidity positions are to the current *desired price*.
3.  **Hook-Based Rewards:** Swap fees collected by the hook (hook fees) are distributed as rewards to LPs who provide liquidity near the desired price.
4.  **Governance:** A dedicated ERC20 token (`GovernanceToken`) allows holders to delegate voting power and participate in polls to set the desired price for specific pools.

## Key Features

*   **Dynamic Desired Price:** Pools have a target price that can be adjusted via governance polls.
*   **Governance Voting:** A robust polling system (`Poll.sol`) allows `GovernanceToken` holders to vote on price adjustments. Features include delegation, different poll stages (PreVote, Vote, FinalVote), major/regular polls, and configurable parameters.
*   **LP Rewards:** LPs earn rewards based on their liquidity's proximity to the desired price, calculated using a weighting mechanism (`HookReward.sol`). Rewards have a lock period.
*   **Custom Hook Fees:** The `DesiredPricePool` hook charges an additional fee on swaps, which funds the LP rewards. This fee is dynamically adjusted based on the swap's impact relative to the desired price.
*   **Helper Contract:** `DesiredPricePoolHelper.sol` simplifies user interactions (minting, adding/removing liquidity, swapping) by abstracting away token transfers, approvals (including Permit2), and Position Manager complexities.
*   **Pausable Governance Token:** The `GovernanceToken` can be paused by the owner.
*   **Uniswap V4 Integration:** Leverages V4 hooks (`beforeInitialize`, `beforeSwap`, `afterSwap`, `beforeAddLiquidity`, `beforeRemoveLiquidity`) for custom logic.

## Architecture

The system consists of several interconnected contracts:

1.  **`DesiredPricePool.sol`**: The main hook contract deployed for each desired price pool.
    *   Inherits from `BaseHook`, `HookReward`, and `DesiredPrice`.
    *   Implements the `IHooks` interface for Uniswap V4.
    *   Handles hook callbacks (swap fees, liquidity updates).
    *   Manages pool-specific fee settings (`lpFees`, `hookFees`).
    *   Coordinates interactions between `DesiredPrice` and `HookReward` logic.
    *   Owned function `createPool` to initialize new V4 pools with this hook.

2.  **`DesiredPrice.sol` (Abstract)**: Manages the desired price governance mechanism for multiple pools.
    *   Stores the `desiredPrice` per `PoolId`.
    *   Manages polling state (`Poll.State`) per `PoolId`.
    *   Handles vote delegation (`delegateVote`, `undelegateVote`).
    *   Handles vote casting (`castVote`).
    *   Executes poll results to update the `desiredPrice` (`execute`, `_setDesiredPrice`).
    *   Interacts with `GovernanceToken`.

3.  **`HookReward.sol` (Abstract)**: Manages the reward calculation and distribution logic for LPs.
    *   Stores collected fees (`feesCollected`) and total weights (`totalWeights`) per `PoolId`.
    *   Tracks pending rewards for each position (`rewards`, `RewardQueue`).
    *   Calculates reward weights based on liquidity position relative to the desired price (`_calculateWeight`).
    *   Handles reward collection (`collectReward`).
    *   Interacts with the `IPositionManager`.

4.  **`GovernanceToken.sol`**: An ERC20 token used for governance.
    *   Standard ERC20 functionality with extensions (`ERC20Pausable`).
    *   Tracks locked balances used for voting power (`_lockedBalances`, `totalLockedBalance`).
    *   Allows locking/unlocking tokens via the `DesiredPrice` contract (`lock`, `unlock`).
    *   Owned by a designated owner, created by the `DesiredPrice` contract deployer.

5.  **`DesiredPricePoolHelper.sol`**: A user-facing contract simplifying interactions.
    *   Provides functions like `mint`, `burn`, `addLiquidity`, `removeLiquidity`, `swapExactIn`, `swapExactOut`.
    *   Handles necessary token approvals (including Permit2 for the `PositionManager`) and transfers.
    *   Uses `EasyPosm` library to interact with `IPositionManager`.
    *   Acts as a temporary holder for NFTs during liquidity modifications (`borrow` modifier).
    *   Implements `unlockCallback` for swaps initiated via `PoolManager.unlock`.

6.  **Libraries (`libraries/`)**:
    *   `Poll.sol`: Core logic for the voting and polling system.
    *   `EasyPosm.sol`: Helper library to simplify `IPositionManager` interactions.
    *   `HookData.sol`: Encodes/decodes custom data passed in hook calls.
    *   `DPPConstants.sol`: Project-specific constants.
    *   `Math.sol`: Supplementary math functions.
    *   `SafeCast128.sol`: Safe casting utilities for 128-bit types.

7.  **Types (`types/`)**: Custom data structures used across the contracts (`VoteInfo`, `PriceUpdate`, `Reward`, `RewardQueue`, `BeforeSwapInfo`).

8.  **Interfaces (`interfaces/`)**: Defines the interfaces for contracts, owner roles, and core components.

## Core Mechanisms

### Desired Price Governance (`DesiredPrice.sol`, `Poll.sol`, `GovernanceToken.sol`)

1.  **Voting Power:** Users lock `GovernanceToken` (`DPP`) to gain voting power within the `DesiredPrice` contract system. Locking is done implicitly via delegation.
2.  **Delegation:** Users delegate their locked `DPP` (voting power) to themselves or other addresses (`delegateVote`, `undelegateVote`). Undelegation has a delay (`UNDELEGATE_DELAY`) if the delegatee has recently voted.
3.  **Polls:** Periodic polls (`Poll.State`) run for each `PoolId`. Polls have stages (PreVote, Vote, FinalVote, PreExecution, ExecutionReady) and can be regular or major (every `CYCLE` polls).
4.  **Casting Votes:** Delegated users (`voters`) cast votes (`castVote`) during the Vote or FinalVote stages, specifying a desired price adjustment range (slots from -10 to +10 relative to the current desired price).
5.  **Execution:** Once a poll reaches the `ExecutionReady` stage, it can be executed (`execute`). The poll calculates the winning slot based on votes (`Poll.count`) and determines the result (Hold, MoveUp, MoveDown, NoMajority, InsufficientVotes). If the result indicates a move, the `desiredPrice` is updated (`_setDesiredPrice`). Execution can be automatic (triggered by pool interactions) or manual based on flags.
6.  **Owner Controls:** The owner can start/pause polls and update poll flags.

### LP Rewards (`HookReward.sol`, `DesiredPricePool.sol`)

1.  **Hook Fees:** Swaps trigger `beforeSwap` and `afterSwap`. `afterSwap` calculates a hook fee based on the base fee (`lpFees`), the hook fee percentage (`hookFees`), and the swap's impact relative to the desired price. This fee is collected in the `feesCollected` mapping.
2.  **Reward Weight Calculation:** When liquidity is added or removed (`beforeAddLiquidity`, `beforeRemoveLiquidity`), the `_updatePendingReward` function calculates a `weight` for that liquidity change. The weight depends on the position's range (`tickLower`, `tickUpper`), the liquidity amount, and its proximity to the `desiredPrice` (`_calculateWeight`). Closer and tighter ranges around the desired price generally get higher weights.
3.  **Reward Queue:** Calculated weights are added to a `RewardQueue` associated with the specific LP position NFT (`positionId`). Each entry includes a timestamp, lock period (`REWARD_LOCK_PERIOD`), and weight.
4.  **Reward Accrual:** Over time, as swap fees are collected (`feesCollected`) and total weight changes (`totalWeights`), the potential reward for a position accumulates proportionally to its weight relative to the total weight in the pool.
5.  **Collecting Rewards:** LPs call `collectReward`. The function first processes the `RewardQueue` for the position, moving weights from the queue to `collectableRewards` after their `lockPeriod` expires (`_updateCollectableReward`). It then calculates the actual token amounts (`_calculateReward`) based on the `collectable` weight, the total weight, and the available `feesCollected`. The calculated amounts are transferred to the recipient.

### Helper Contract (`DesiredPricePoolHelper.sol`)

The helper contract simplifies user interactions:

*   **Liquidity:** `mint`, `addLiquidity`, `removeLiquidity`, `burn` functions wrap the corresponding `IPositionManager` calls. They handle:
    *   Receiving tokens/ETH from the user (`_receive`).
    *   Approving the `PositionManager` (via Permit2) to spend the helper's tokens (`_approve`).
    *   Calling the `IPositionManager` using `EasyPosm`.
    *   Sending back excess tokens/ETH (`_send`).
    *   Passing encoded `hookData` (containing the `tokenId`) required by the `DesiredPricePool` hook.
    *   Using the `borrow` modifier to temporarily hold the user's position NFT.
*   **Swaps:** `swapExactIn` and `swapExactOut` initiate swaps via `PoolManager.unlock`. The logic is handled in the `_unlockCallback`, which executes the swap, settles currency deltas (`_solve`), and allows the `DesiredPricePool` hook to take its fee (`dpp.takeHookFee`).

## Getting Started / Usage (Conceptual)

1.  **Deployment:** Deploy `DesiredPricePool` (which deploys `GovernanceToken`). Deploy `DesiredPricePoolHelper`.
2.  **Pool Creation:** The owner calls `DesiredPricePool.createPool` to initialize a new Uniswap V4 pool with the DPP hook, setting the initial desired price.
3.  **LP Interaction (via Helper):**
    *   Approve `DesiredPricePoolHelper` to spend tokens.
    *   Call `helper.mint(...)` or `helper.addLiquidity(...)` to provide liquidity.
    *   Call `helper.removeLiquidity(...)` or `helper.burn(...)` to remove liquidity.
    *   Call `helper.collectReward(...)` (after reward lock period) to claim earned hook fees.
4.  **Swapper Interaction (via Helper):**
    *   Approve `DesiredPricePoolHelper` to spend input tokens.
    *   Call `helper.swapExactIn(...)` or `helper.swapExactOut(...)`.
5.  **Governance:**
    *   Acquire `GovernanceToken` (`DPP`).
    *   Optionally, delegate voting power using `DesiredPricePool.delegateVote(...)`.
    *   Cast votes during active poll periods using `DesiredPricePool.castVote(...)`.
    *   Anyone can trigger poll execution (if ready) by calling `DesiredPricePool.execute(...)` or interacting with the pool if `FLAG_IN_TIME_EXECUTION` is set.

## Security Considerations

*   The code includes reentrancy guards (`HookReward`).
*   Ownership controls critical functions like pausing the token, creating pools, and managing polls.
*   Uses SafeCast for type conversions.
*   **Audits:** This code has NOT been professionally audited. Use with extreme caution. Complex interactions between hooks, governance, and rewards require thorough security reviews.

## Future Work / TODOs


## License

This project primarily uses the MIT license, as indicated by the SPDX identifiers in most files. Note that `libraries/EasyPosm.sol` uses GPL-2.0-or-later. Ensure compliance with both licenses if reusing components.