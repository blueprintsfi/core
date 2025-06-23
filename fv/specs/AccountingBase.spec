using AccountingHelper as helper;

methods {
	function addFlashValue(uint256, uint256) external envfree;
	function subtractFlashValue(uint256, uint256) external envfree;
	function settleFlashBalance(uint256) external envfree;
	function mint(uint256, uint256) external envfree;
	function burn(uint256, uint256) external envfree;

	function balanceOf(uint256) external returns (uint256) envfree;

	function exttload(uint256) external returns (uint256) envfree;
	function extsload(uint256) external returns (uint256) envfree;

	function helper.hash(uint256 val) external returns (uint256) envfree;
	function helper.getFirstArg() external returns (uint256);
	function helper.getSecondArg() external returns (uint256);
}

function to_int(mathint val) returns int {
	return assert_int256(val >= 2 ^ 255 ? val - 2 ^ 256 : val);
}

function abs(mathint val) returns mathint {
	return val < 0 ? -val : val;
}

function tload(mathint slot) returns uint {
	return exttload(assert_uint256(slot));
}

function sload(mathint slot) returns uint {
	return extsload(assert_uint256(slot));
}

function hash(uint val) returns uint {
	return helper.hash(val);
}

function transientOverflowRelationalInvariant(uint preimage) returns mathint {
	mathint slot = hash(preimage);
	return abs(to_int(tload(slot + 1))) / 2;
}

strong invariant transientOverflowRelationalInvariantIsZeroAtInitialState(uint preimage)
	transientOverflowRelationalInvariant(preimage) == 0
	{ preserved { require(false, "we only want to restrict the initial state"); } }

rule transientOverflowComputationalInfeasibility(uint preimage) {
	mathint beforeValue = transientOverflowRelationalInvariant(preimage);

	env e;
	method f;
	calldataarg args;
	f(e, args);

	mathint afterValue = transientOverflowRelationalInvariant(preimage);
	assert afterValue <= beforeValue + 1;
}

function storageOverflowRelationalInvariant(uint preimage) returns mathint {
	mathint slot = hash(preimage);
	// we have to take into account the sum of the transient and storage values
	// transient value can be zeroed out by ignoring the msb bits
	mathint corr = tload(slot) % 2 == 0 ? 0 : abs(to_int(tload(slot + 1)));
	return (sload(slot + 1) + corr) / 2;
}

strong invariant storageOverflowRelationalInvariantIsZeroAtInitialState(uint preimage)
	storageOverflowRelationalInvariant(preimage) == 0
	{ preserved { require(false, "we only want to restrict the initial state"); } }

rule storageOverflowComputationalInfeasibility(uint preimage) {
	mathint beforeValue = storageOverflowRelationalInvariant(preimage);

	env e;
	method f;
	calldataarg args;
	f(e, args);

	mathint afterValue = storageOverflowRelationalInvariant(preimage);
	assert afterValue <= beforeValue + 1;
}

function requireTransientAssumptions(uint preimage) {
	require(transientOverflowRelationalInvariant(preimage) < 2 ^ 250, "computationally infeasible"); // rough bounds
}

function requireStorageAssumptions(uint preimage) {
	requireTransientAssumptions(preimage);
	require(storageOverflowRelationalInvariant(preimage) < 2 ^ 250, "computationally infeasible"); // rough bounds
}
