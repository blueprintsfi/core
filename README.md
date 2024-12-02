## Blueprints Core

The core contract is the `BlueprintManager`. It has the functionality of an ERC6909, except is skimmed of events for gas consumption reasons.

The `BlueprintManager` allows blueprints to mint new tokens within it to express users' positions. Users can also use blueprints to perform more complex actions through `cook()`. During the execution, the manager calls blueprints asking them to generate a state change of the blueprint's and user's balances (disallowing creating external tokens), and applies the balance changes.

To apply the balance changes, `FlashAccounting` is used, so that actions that cancel out the balance changes won't even require reading the state. Flash accounting can handle temporarily overflowing balance changes, as long as they can be added/subtracted to/from the balance at the end of the `cook()` invocation. Recursive `cook()` invocations are permitted. If a `cook()` invocation is on the call stack, one can take flash loans using `credit()` functions (but permission can be restricted by the `cook()` caller).

Overall, the flash accounting is relatively similar to the one in [Uniswap v4](https://github.com/Uniswap/v4-core), except:
- flash accounting settles outstanding credits and debits automatically
- unlocking (cooking) is not disallowed when another such operation is being perfomed (i.e. reentrancy is allowed)
- access to functions changing flash accounting can be restricted by the `cook()` caller
	- it means it is no longer users' responsibility not to make untrusted calls when flash accounting is active not to allow for reverts (although the action may cause a revert of the whole transaction if that separately valid action would cause a later under/overflow in storage balances due to new balance changes)
- balance changes and total balance change are not restricted to `int128`s, the only real restriction is that any single operation must fit the amount in 256 bits and the final balance must fit in an `uint256`.

## Blueprints

The repo also contains several blueprints:
- `NativeBlueprint` – wraps native tokens into a token in the system
- `ERC20Blueprint` – wraps ERC20 tokens into a token in the system; has ERC777 support
- `VestingBlueprint` – creates vesting positions according to a custom vesting schedule
	- `LinearCliffVestingSchedule` – a linear vesting schedule with a cliff
- `BasketBlueprint` – allows for creation of baskets of tokens expressible by a single token

## Safety

This is experimental software and is provided on an "as is" and "as available" basis.

We **do not give any warranties** and **will not be liable for any loss** incurred through any use of this codebase.

## Contributing

Contributions are highly welcome!

All contributions must come in two stages (you can also contribute in only one of these):
1. Create an issue describing the suggested changes and why are they warranted. \
	Note: changes will be discussed in the comments section.
2. After the changes have been approved by a Blueprints team member, prepare a PR that implements the proposed changes, together with applicable Foundry tests.

Stage 1 can be skipped in case the contribution doesn't change the way contracts behave.

Against Solidity's Style Guide, we use tabs for indentation. We try not to put more than 80 characters in a line (tabs are of size 4), but if that's impossible without doing really weird things, it's fine to go up to 100. I recommend using rulers in your text editor. The 80/100 policy is not so strict in tests.

### Areas for improvement

If you want to contribute, you could:
- take a look at existing issues and chime in in the discussion!
- find areas to improve gas efficiency
	- idea: reading `TokenOp`s straight from returndata in the manager could save a lot of gas; also to put them in a custom struct that puts the elements in place, not creates an array of pointers to structs
- solve or answer any existing `todo`s
- allow for balances larger than `type(uint256).max` (to be discussed)
- add permit-like functionality to the manager, both for approvals and operators
- add permit2 support to the `ERC20Blueprint` (use it from [solady](https://github.com/vectorized/solady) and add extended support there?)
- consider how opinionated the token creation should be (whether we want to enforce "good practices") for ensuring token fungibility:
	- should we continue to enforce that a single token in vesting or in a basket must have the collateral amounts of GCD 1?
		- if yes, should we continue to calculate the GCD on chain?
	- should we enforce that a basket token must have token ids sorted?
		- if yes, should we do the sorting on chain?
- figure how to merge liquidity across (and extend the system to) L2s & L3s without forcing users to take risks associated with chains irrelevant to their transaction, ideally without having to transact on mainnet
- consider whether basic wrappers should be created within the manager for efficiency or whether the manager should remain minimal for security reasons
- consider a design where tokens of different ids could be put in a specific slot (for example storing `keccak256(abi.encode(tokenId, amount))` in a slot a merkle tree of such values), then completely updating a position modify a single slot instead of two slots, including a likely initialization of one and freeing of the other; this also enables Monad-like parallelization much easier
