// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {FINCR} from "src/FINCR.sol";
import {FINCRHandler} from "./helpers/FINCRHandler.sol";

/// @notice Conservation, authorization and rollback properties over arbitrary token call sequences.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract FINCRInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 internal constant ACTOR_COUNT = 6;
    FINCRHandler internal handler;
    FINCR internal token;

    function setUp() public {
        handler = new FINCRHandler();
        token = handler.token();
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.burn.selector;
        selectors[4] = handler.rejectOverdraw.selector;
        selectors[5] = handler.revokeAndRejectSpend.selector;
        selectors[6] = handler.rejectOverdrawnDelegatedSpend.selector;
        selectors[7] = handler.rejectZeroRecipient.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_BalancesSumToSupplyAndOnlyVoluntaryBurnsReduceIt() public view {
        uint256 sum;
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, token.totalSupply(), "balances do not account for the entire live supply");
        assertEq(token.totalSupply() + handler.burned(), SUPPLY, "unexpected mint, burn or transfer tax");
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0, "token unexpectedly diverted funds to itself");
    }

    function invariant_EachHolderOwnsExactlyItsAllocationPlusReceiptsMinusSpendsAndBurns() public view {
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            address actor = handler.actors(i);
            assertEq(token.balanceOf(actor), handler.expectedBalance(actor), "holder accounting mismatch");
        }
    }

    function invariant_AllowancesChangeOnlyByApprovalOrSuccessfulAuthorizedSpend() public view {
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            address owner = handler.actors(i);
            for (uint256 j; j < ACTOR_COUNT; ++j) {
                address spender = handler.actors(j);
                assertEq(
                    token.allowance(owner, spender),
                    handler.expectedAllowance(owner, spender),
                    "allowance leaked, was restored or was consumed by a reverted transfer"
                );
            }
            assertEq(token.allowance(owner, address(0)), 0);
        }
    }

    function invariant_LaunchIdentityAndCodeCannotChange() public view {
        assertEq(token.name(), "FINANCIER");
        assertEq(token.symbol(), "FINCR");
        assertEq(token.decimals(), 18);
        assertEq(token.initialSupply(), SUPPLY);
        assertEq(keccak256(address(token).code), 0x946270e19519507b25f0e64ba542b050d325476e1a397aadf1f64ea23d16064c);
    }

    /// @dev Every sequence must leave each holder able to voluntarily destroy its remaining balance.
    function afterInvariant() public {
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            handler.burn(i, handler.expectedBalance(handler.actors(i)));
        }
        assertEq(token.totalSupply(), 0);
        assertEq(handler.burned(), SUPPLY);
        invariant_BalancesSumToSupplyAndOnlyVoluntaryBurnsReduceIt();
        invariant_EachHolderOwnsExactlyItsAllocationPlusReceiptsMinusSpendsAndBurns();
        invariant_AllowancesChangeOnlyByApprovalOrSuccessfulAuthorizedSpend();
        invariant_LaunchIdentityAndCodeCannotChange();
    }

    /// @dev Deterministically prove that the handler reaches value-moving and reverting paths.
    function testHandlerExercisesTransfersAllowancesBurnsAndFailures() public {
        handler.transfer(1, 4, 100);
        handler.approve(4, 5, 80);
        handler.transferFrom(4, 5, 3, 30);
        handler.burn(4, 10);
        handler.rejectOverdraw(4, 61, false);
        handler.rejectOverdraw(4, type(uint256).max, true);
        handler.rejectZeroRecipient(4, 5, 1, true);
        handler.rejectOverdrawnDelegatedSpend(4, 5, 61, false);
        handler.revokeAndRejectSpend(4, 5, 3, 1);
        assertEq(handler.positiveTransfers(), 1);
        assertEq(handler.positiveDelegatedTransfers(), 1);
        assertEq(handler.burned(), 10);
        assertEq(handler.rejectedCalls(), 5);
        invariant_BalancesSumToSupplyAndOnlyVoluntaryBurnsReduceIt();
        invariant_EachHolderOwnsExactlyItsAllocationPlusReceiptsMinusSpendsAndBurns();
        invariant_AllowancesChangeOnlyByApprovalOrSuccessfulAuthorizedSpend();
        invariant_LaunchIdentityAndCodeCannotChange();
        afterInvariant();
    }
}
