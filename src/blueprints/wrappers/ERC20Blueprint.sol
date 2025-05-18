// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BasicBlueprint, TokenOp, IBlueprintManager, zero, oneOpArray} from "../BasicBlueprint.sol";
import {SafeTransferLib, ERC20} from "solmate/utils/SafeTransferLib.sol";

interface IERC1820Registry {
	function setInterfaceImplementer(address addr, bytes32 interfaceHash, address implementer) external;
}

interface IDepositor {
	function depositCallback(address erc20, bytes calldata callbackData) external;
}

interface IPermit2 {
	function permitWitnessTransferFrom(
		PermitBatchTransferFrom memory permit,
		SignatureTransferDetails[] calldata transferDetails,
		address owner,
		bytes32 witness,
		string calldata witnessTypeString,
		bytes calldata signature
	) external;

	struct PermitBatchTransferFrom {
		TokenPermissions[] permitted;
		uint256 nonce;
		uint256 deadline;
	}

	struct TokenPermissions {
		address token;
		uint256 amount;
	}

	struct SignatureTransferDetails {
		address to;
		uint256 requestedAmount;
	}
}

bytes32 constant DEPOSIT_TYPEHASH = keccak256(bytes("Deposit(address to,uint256 toSubaccount)"));
string constant WITNESS_TYPE_STRING =
	"Deposit witness)"
	"Deposit(address to,uint256 toSubaccount)"
	"TokenPermissions(address token,uint256 amount)";

function getWitness(address to, uint256 toSubaccount) pure returns (bytes32 witness) {
	uint256 _to = uint160(to);
	bytes32 typehash = DEPOSIT_TYPEHASH;
	assembly ("memory-safe") {
		let ptr := mload(0x40)
		mstore(ptr, typehash)
		mstore(add(ptr, 0x20), _to)
		mstore(add(ptr, 0x40), toSubaccount)

		witness := keccak256(ptr, 0x60)
	}
}

contract ERC20Blueprint is BasicBlueprint {
	error ReentrantDeposit();
	error BalanceOverflow();
	error InexactPermit2Deposit();

	address internal constant registry = 0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24;
	IPermit2 public immutable permit2;

	constructor(IBlueprintManager _manager, IPermit2 _permit2) BasicBlueprint(_manager) {
		permit2 = _permit2;
	}

	function executeAction(bytes calldata action) external onlyManager returns (
		uint256,
		TokenOp[] memory /*mint*/,
		TokenOp[] memory /*burn*/,
		TokenOp[] memory /*give*/,
		TokenOp[] memory /*take*/
	) {
		(address erc20, address to, uint256 amount, bool fromSubaccount) =
			abi.decode(action, (address, address, uint256, bool));

		SafeTransferLib.safeTransfer(ERC20(erc20), to, amount);

		TokenOp[] memory arr = oneOpArray(uint256(uint160(erc20)), amount);
		return (
			uint256(uint160(to)), // doesn't matter if !fromSubaccount
			zero(),
			arr,
			fromSubaccount ? arr : zero(),
			zero()
		);
	}

	function tokensReceived(
		address operator,
		address from,
		address to,
		uint256 amount,
		bytes calldata data,
		bytes calldata /*operatorData*/
	) external {
		// do only if we aren't pulling funds, where tokens are accounted for in
		// the balance-measuring functions
		if (operator != address(this) && to == address(this)) {
			uint256 savedBalance = _getSavedBalance(msg.sender);
			// if saved, offset the change due to this deposit
			if (savedBalance != type(uint256).max)
				_saveBalance(msg.sender, savedBalance + amount);

			// we can override the receiver address, let's save it in `from`
			if (data.length == 32)
				(from) = abi.decode(data, (address));

			manager.mint(from, uint256(uint160(msg.sender)), amount);
		}
	}

	function deposit(
		address erc20,
		address to,
		uint256 toSubaccount,
		uint256 amount
	) external returns (uint256 deposited) {
		return _deposit(erc20, msg.sender, to, toSubaccount, amount);
	}

	function permitDeposit(
		address erc20,
		address to,
		uint256 toSubaccount,
		uint256 amount,
		address owner,
		uint256 deadline,
		uint8 v,
		bytes32 r,
		bytes32 s
	) external returns (uint256 deposited) {
		if (owner != to && owner != msg.sender)
			revert AccessDenied();

		ERC20(erc20).permit(owner, address(this), amount, deadline, v, r, s);

		return _deposit(erc20, owner, to, toSubaccount, amount);
	}

	// NOTE: incompatible with fee-on-transfer tokens, one token should be
	// approved only once in the permitted array
	function permit2Deposit(
		IPermit2.PermitBatchTransferFrom calldata permit,
		address owner,
		address to,
		uint256 toSubaccount,
		bytes calldata signature
	) external {
		IPermit2.TokenPermissions[] calldata permitted = permit.permitted;
		IPermit2.SignatureTransferDetails[] memory transfers =
			new IPermit2.SignatureTransferDetails[](permitted.length);
		for (uint256 i = 0; i < permitted.length; i++) {
			address token = permitted[i].token;
			transfers[i] = IPermit2.SignatureTransferDetails({
				to: address(this),
				requestedAmount: permitted[i].amount
			});
			_saveBalance(token, _getBalance(token));
		}
		permit2.permitWitnessTransferFrom(
			permit,
			transfers,
			owner,
			getWitness(to, toSubaccount),
			WITNESS_TYPE_STRING,
			signature
		);
		for (uint256 i = 0; i < permitted.length; i++) {
			if (_mintNewBalance(permitted[i].token, to, toSubaccount) < permitted[i].amount)
				revert InexactPermit2Deposit();
		}
	}

	function depositWithCallback(
		address erc20,
		address callback,
		bytes calldata callbackData
	) external returns (uint256 deposited) {
		_saveBalance(erc20, _getBalance(erc20));

		IDepositor(callback).depositCallback(erc20, callbackData);

		return _mintNewBalance(erc20, msg.sender, 0);
	}

	function _deposit(
		address erc20,
		address from,
		address to,
		uint256 toSubaccount,
		uint256 amount
	) internal returns (uint256 deposited) {
		_saveBalance(erc20, _getBalance(erc20));

		SafeTransferLib.safeTransferFrom(ERC20(erc20), from, address(this), amount);

		return _mintNewBalance(erc20, to, toSubaccount);
	}

	function _getBalance(address erc20) internal view returns (uint256) {
		return ERC20(erc20).balanceOf(address(this));
	}

	function _saveBalance(address erc20, uint256 _balance) internal {
		if (_balance == type(uint256).max)
			revert BalanceOverflow();

		assembly {
			// clean potentially dirty bits
			erc20 := shr(96, shl(96, erc20))
			tstore(erc20, add(_balance, 1))
		}
	}

	function _getSavedBalance(address erc20) internal view returns (uint256 _balance) {
		assembly {
			// clean potentially dirty bits
			erc20 := shr(96, shl(96, erc20))
			// make sure that the balance has been saved since this can overflow!
			_balance := sub(tload(erc20), 1)
		}
	}

	function _mintNewBalance(address erc20, address to, uint256 toSubaccount) internal returns (
		uint256 delta
	) {
		uint256 newBalance = _getBalance(erc20);
		uint256 oldBalance = _getSavedBalance(erc20);
		delta = newBalance - oldBalance;

		manager.mint(to, toSubaccount, uint256(uint160(erc20)), delta);
		_saveBalance(erc20, newBalance);
	}

	function setERC1820Registry() external {
		IERC1820Registry(registry).setInterfaceImplementer(
			address(this),
			keccak256("ERC777TokensRecipient"),
			address(this)
		);
	}
}
