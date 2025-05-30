methods {
	function addFlashValue(uint256, uint256) external envfree;
	function subtractFlashValue(uint256, uint256) external envfree;
	function readAndNullifyFlashValue(uint256) external envfree;
	function hash(uint256) external returns (uint256) envfree;
	function exttload(uint256) external returns (uint256) envfree;
	function mint(uint256, uint256) external envfree;
	function burn(uint256, uint256) external envfree;
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

function anyCallWithArgs(method f, uint preimage, uint delta) returns bool {
	if (f.selector == sig:addFlashValue(uint256, uint256).selector) {
		addFlashValue@withrevert(preimage, delta);
	} else if (f.selector == sig:subtractFlashValue(uint256, uint256).selector) {
		subtractFlashValue@withrevert(preimage, delta);
	} else if (f.selector == sig:mint(uint256, uint256).selector) {
		mint@withrevert(preimage, delta);
	} else if (f.selector == sig:burn(uint256, uint256).selector) {
		burn@withrevert(preimage, delta);
	} else if (f.selector == sig:readAndNullifyFlashValue(uint256).selector) {
		readAndNullifyFlashValue@withrevert(preimage);
	} else {
		// consider any other functions, too
		env e;
		calldataarg args;
		f@withrevert(e, args);
	}
	return lastReverted;
}

rule absMsbDoesntIncreaseByMoreThan2(uint preimage) {
	uint slot = hash(preimage);
	mathint beforeValue = abs(to_int(tload(slot + 1))) / 2;

	method f;
	uint delta;
	require(!anyCallWithArgs(f, preimage, delta), "reverting calls don't cause state changes");

	mathint afterValue = abs(to_int(tload(slot + 1))) / 2;
	assert afterValue <= beforeValue + 1;
}

function currentTransientValue(uint256 preimage) returns mathint {
	uint256 slot = hash(preimage);
	uint256 lsb = tload(slot);
	bool extension = lsb % 2 == 1;
	mathint lsb_int = to_int(lsb - (lsb % 2)) / 2;

	if (extension) {
		int val = to_int(tload(slot + 1));
		// can cap due to computational infeasibility as proven by msbDoesntChangeByMoreThan2
		require(abs(val) < 2 ^ 254, "computationally infeasible"); // rough bounds
		return lsb_int + val * 2 ^ 255;
	}
	return lsb_int;
}

rule properTransientChange(uint preimage) {
	mathint beforeValue = currentTransientValue(preimage);

	method f;
	uint delta;
	require(!anyCallWithArgs(f, preimage, delta), "reverting calls don't cause state changes");

	mathint afterValue = currentTransientValue(preimage);

	if (f.selector == sig:addFlashValue(uint256, uint256).selector) {
		assert afterValue - beforeValue == delta;
	} else if (f.selector == sig:subtractFlashValue(uint256, uint256).selector) {
		assert beforeValue - afterValue == delta;
	} else if (f.selector == sig:readAndNullifyFlashValue(uint256).selector) {
		assert afterValue == 0;
	} else {
		assert afterValue == beforeValue;
	}
}

strong invariant transientMsbNeverPointedToWhenZero(uint preimage)
	(tload(hash(preimage)) % 2 == 1) => (tload(hash(preimage) + 1) != 0);

rule properRevert(uint preimage) {
	requireInvariant transientMsbNeverPointedToWhenZero(preimage);
	// mathint beforeValue = currentTransientValue(preimage);

	method f;
	uint delta;
	bool reverted = anyCallWithArgs(f, preimage, delta);

	assert (f.selector == sig:addFlashValue(uint256, uint256).selector ||
		f.selector == sig:subtractFlashValue(uint256, uint256).selector) =>
			!reverted;
	// assert f.selector == sig:readAndNullifyFlashValue(uint256).selector =>
	// 	(reverted <=> abs(beforeValue) >= 2 ^ 256);
}

// rule properRead(uint preimage) {
// 	requireInvariant msbNeverPointedToWhenZero(preimage);
// 	mathint beforeValue = currentValue(preimage);

// 	uint positive;
// 	uint negative;
// 	(positive, negative) = readAndNullifyFlashValue(preimage);

// 	assert beforeValue >= 0 => (positive == beforeValue && negative == 0);
// 	assert beforeValue < 0 => (negative == abs(beforeValue) && positive == 0);
// }

rule doesntChangeAnythingElse(uint preimage, uint preimageOther) {
	mathint beforeValue = currentTransientValue(preimageOther);

	method f;
	uint delta;
	anyCallWithArgs(f, preimage, delta);

	assert (preimage != preimageOther) => (currentTransientValue(preimageOther) == beforeValue);
}
