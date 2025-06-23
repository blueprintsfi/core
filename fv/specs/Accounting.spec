import "AccountingBase.spec";

use invariant transientOverflowRelationalInvariantIsZeroAtInitialState;
use invariant storageOverflowRelationalInvariantIsZeroAtInitialState;
use rule transientOverflowComputationalInfeasibility;
use rule storageOverflowComputationalInfeasibility;

strong invariant transientMsbNeverPointedToWhenZero(uint preimage)
	(tload(hash(preimage)) % 2 == 1) => (tload(hash(preimage) + 1) != 0);

strong invariant storageMsbNeverPointedToWhenZero(uint preimage)
	(sload(hash(preimage)) / 2 ^ 255 == 1) <=> (sload(hash(preimage) + 1) != 0)
	{ preserved { requireStorageAssumptions(preimage); } }

function anyCallWithArgs(method f, uint preimage, uint delta) returns bool {
	calldataarg args;
	env e;
	require(e.msg.value == 0, "we don't play with msg.value in these contracts");

	if (
		f.selector == sig:addFlashValue(uint256, uint256).selector ||
		f.selector == sig:subtractFlashValue(uint256, uint256).selector ||
		f.selector == sig:mint(uint256, uint256).selector ||
		f.selector == sig:burn(uint256, uint256).selector ||
		f.selector == sig:readAndNullifyFlashValue(uint256).selector
	) {
		require(helper.getFirstArg@withrevert(e, args) == preimage, "pin preimage");
		assert !lastReverted; // just in case, we don't want to miss violations
		if (f.selector != sig:readAndNullifyFlashValue(uint256).selector) {
			require(helper.getSecondArg@withrevert(e, args) == delta, "pin delta");
			assert !lastReverted; // just in case, we don't want to miss violations
		}
	}
	currentContract.f@withrevert(e, args);
	return lastReverted;
}

function currentTransientValue(uint256 preimage) returns mathint {
	uint256 slot = hash(preimage);
	uint256 lsb = tload(slot);
	bool extension = lsb % 2 == 1;
	mathint lsb_int = to_int(lsb - (lsb % 2)) / 2;

	if (extension) {
		int val = to_int(tload(slot + 1));
		requireTransientAssumptions(preimage);
		return lsb_int + val * 2 ^ 255;
	}
	return lsb_int;
}

function currentStorageValue(uint256 preimage) returns mathint {
	uint256 slot = hash(preimage);
	uint256 lsb = sload(slot);
	mathint lsb_uint = lsb - (lsb / 2 ^ 255 * 2 ^ 255);

	uint msb = sload(slot + 1);
	requireStorageAssumptions(preimage);
	return lsb_uint + msb * 2 ^ 255;
}

rule properStateChange(uint preimage) {
	requireInvariant transientMsbNeverPointedToWhenZero(preimage);
	requireInvariant storageMsbNeverPointedToWhenZero(preimage);
	mathint beforeTransientValue = currentTransientValue(preimage);
	mathint beforeStorageValue = currentStorageValue(preimage);

	method f;
	uint delta;
	require(!anyCallWithArgs(f, preimage, delta), "reverting calls don't cause state changes");

	mathint afterTransientValue = currentTransientValue(preimage);
	mathint afterStorageValue = currentStorageValue(preimage);

	if (f.selector == sig:addFlashValue(uint256, uint256).selector) {
		assert afterTransientValue - beforeTransientValue == delta;
		assert beforeStorageValue == afterStorageValue;
	} else if (f.selector == sig:subtractFlashValue(uint256, uint256).selector) {
		assert beforeTransientValue - afterTransientValue == delta;
		assert beforeStorageValue == afterStorageValue;
	} else if (f.selector == sig:readAndNullifyFlashValue(uint256).selector) {
		assert afterTransientValue == 0;
		assert afterStorageValue == beforeStorageValue + beforeTransientValue;
	} else if (f.selector == sig:mint(uint256, uint256).selector) {
		assert beforeTransientValue == afterTransientValue;
		assert afterStorageValue - beforeStorageValue == delta;
	} else if (f.selector == sig:burn(uint256, uint256).selector) {
		assert beforeTransientValue == afterTransientValue;
		assert beforeStorageValue - afterStorageValue == delta;
	} else {
		assert beforeTransientValue == afterTransientValue;
		assert beforeStorageValue == afterStorageValue;
	}
}

rule properRevert(uint preimage) {
	requireInvariant transientMsbNeverPointedToWhenZero(preimage);
	requireInvariant storageMsbNeverPointedToWhenZero(preimage);
	mathint beforeTransientValue = currentTransientValue(preimage);
	mathint beforeStorageValue = currentStorageValue(preimage);

	method f;
	uint delta;
	bool reverted = anyCallWithArgs(f, preimage, delta);

	assert (
		f.selector == sig:addFlashValue(uint256, uint256).selector ||
		f.selector == sig:subtractFlashValue(uint256, uint256).selector ||
		f.selector == sig:mint(uint256, uint256).selector
	) => !reverted;
	assert f.selector == sig:readAndNullifyFlashValue(uint256).selector => (
		reverted <=> beforeStorageValue + beforeTransientValue < 0
	);
	assert f.selector == sig:burn(uint256, uint256).selector => (
		reverted <=> beforeStorageValue < delta
	);
}

rule balanceReadingCorrect(uint preimage) {
	requireInvariant storageMsbNeverPointedToWhenZero(preimage);
	mathint value = currentStorageValue(preimage);

	assert balanceOf(preimage) == (value >= 2 ^ 256 ? 2 ^ 256 - 1 : value);
}

// if a function is not supposed to change a value for the same preimage, but
// in transient/storage, it's enforced in properStateChange already
rule doesntChangeAnythingElse(uint preimage, uint preimageOther) {
	mathint beforeTransientValue = currentTransientValue(preimageOther);
	mathint beforeStorageValue = currentStorageValue(preimageOther);

	method f;
	uint delta;
	anyCallWithArgs(f, preimage, delta);

	assert (preimage != preimageOther) => (
		currentTransientValue(preimageOther) == beforeTransientValue &&
		currentStorageValue(preimageOther) == beforeStorageValue
	);
}
