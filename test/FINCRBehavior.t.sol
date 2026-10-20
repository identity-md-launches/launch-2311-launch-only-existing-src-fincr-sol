// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {FINCR} from "src/FINCR.sol";

/// @notice Complements FINCRLaunchTest with ERC20 boundary, authorization and rollback properties.
/// @dev All labeled addresses are local test actors, not launch configuration.
/// forge-config: default.fuzz.runs = 1000
contract FINCRBehaviorTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    FINCR internal token;
    address internal alice;
    address internal bob;
    address internal spender;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        alice = makeAddr("FINCR behavior holder");
        bob = makeAddr("FINCR behavior recipient");
        spender = makeAddr("FINCR behavior spender");
        token = new FINCR(SUPPLY);
    }

    function testConstructorEmitsExactlyOneMintOfTheWholeSupply() public {
        vm.recordLogs();
        FINCR deployed = new FINCR(SUPPLY);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(deployed));
        assertEq(logs[0].topics.length, 3);
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(this)))));
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
        assertEq(deployed.totalSupply(), SUPPLY);
        assertEq(deployed.balanceOf(address(this)), SUPPLY);
    }

    function testConstructorRejectsExplicitInvalidBoundaries() public {
        uint256[5] memory invalid = [uint256(0), 1, 99, 101, type(uint256).max];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(bytes("invalid supply"));
            new FINCR(invalid[i]);
        }
    }

    function testZeroTransfersAndZeroBurnFromEmptyHolderEmitEvents() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 0);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));

        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 0);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 0));

        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, address(0), 0);
        vm.prank(alice);
        token.burn(0);
        _assertUntouchedSupply();
        assertEq(token.allowance(alice, spender), 0);
    }

    function testOneBaseUnitCanBeTransferredDelegatedAndBurned() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), alice, 1);
        assertTrue(token.transfer(alice, 1));

        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(alice, spender, 1);
        vm.prank(alice);
        assertTrue(token.approve(spender, 1));

        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 1);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 1));
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 1);

        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(bob, address(0), 1);
        vm.prank(bob);
        token.burn(1);
        assertEq(token.totalSupply(), SUPPLY - 1);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.initialSupply(), SUPPLY);
    }

    function testZeroAddressIsNeverATransferOrApprovalDestination() public {
        uint256[4] memory amounts = [uint256(0), 1, SUPPLY, type(uint256).max];
        for (uint256 i; i < amounts.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            token.transfer(address(0), amounts[i]);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
            token.approve(address(0), amounts[i]);
            assertEq(token.allowance(address(this), address(0)), 0);
            _assertUntouchedSupply();
        }
    }

    function testTransferFromZeroOwnerCannotMintEvenForZeroAmount() public {
        // OpenZeppelin 5.4 rejects the invalid approver while spending a zero allowance.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(0), bob, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(0), bob, 1);
        _assertUntouchedSupply();
    }

    function testMaximumTransferAndBurnCannotOverflowBalances() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
            )
        );
        token.transfer(alice, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
            )
        );
        token.burn(type(uint256).max);
        _assertUntouchedSupply();
    }

    function testApprovalsAreReplacedAndCanBeRevokedAfterPartialSpend() public {
        assertTrue(token.transfer(alice, 100));
        vm.startPrank(alice);
        assertTrue(token.approve(spender, 80));
        assertTrue(token.approve(spender, 40));
        vm.stopPrank();
        assertEq(token.allowance(alice, spender), 40);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 10));
        assertEq(token.allowance(alice, spender), 30);
        vm.prank(alice);
        assertTrue(token.approve(spender, 0));

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(alice), 90);
        assertEq(token.balanceOf(bob), 10);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testInfiniteAllowancePersistsButMaxMinusOneIsFinite() public {
        assertTrue(token.transfer(alice, 3));
        vm.prank(alice);
        assertTrue(token.approve(spender, type(uint256).max));
        for (uint256 i; i < 2; ++i) {
            vm.prank(spender);
            assertTrue(token.transferFrom(alice, bob, 1));
            assertEq(token.allowance(alice, spender), type(uint256).max);
        }
        vm.prank(alice);
        assertTrue(token.approve(spender, type(uint256).max - 1));
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 1));
        assertEq(token.allowance(alice, spender), type(uint256).max - 2);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 3);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testHolderStillNeedsAllowanceToUseTransferFromOnItself() public {
        assertTrue(token.transfer(alice, 1));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transferFrom(alice, bob, 1);
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(bob), 0);

        vm.startPrank(alice);
        assertTrue(token.approve(alice, 1));
        assertTrue(token.transferFrom(alice, bob, 1));
        vm.stopPrank();
        assertEq(token.allowance(alice, alice), 0);
        assertEq(token.balanceOf(bob), 1);
    }

    function testApprovalDoesNotAuthorizeBurningAnotherHoldersBalance() public {
        assertTrue(token.transfer(alice, 100));
        assertTrue(token.transfer(spender, 7));
        vm.prank(alice);
        assertTrue(token.approve(spender, type(uint256).max));
        vm.prank(spender);
        token.burn(7);
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.balanceOf(alice), 100);
        assertEq(token.allowance(alice, spender), type(uint256).max);
        assertEq(token.totalSupply(), SUPPLY - 7);

        vm.prank(spender);
        (bool ok,) = address(token).call(abi.encodeWithSignature("burnFrom(address,uint256)", alice, 1));
        assertFalse(ok, "approved spender unexpectedly acquired burnFrom authority");
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, spender, 0, 1));
        vm.prank(spender);
        token.burn(1);
        assertEq(token.balanceOf(alice), 100);
        assertEq(token.totalSupply(), SUPPLY - 7);
    }

    function testBurnedBalanceCannotBeSpentUsingAnExistingAllowance() public {
        assertTrue(token.transfer(alice, 100));
        vm.startPrank(alice);
        assertTrue(token.approve(spender, 100));
        token.burn(60);
        vm.stopPrank();
        assertEq(token.allowance(alice, spender), 100);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 40, 41));
        vm.prank(spender);
        token.transferFrom(alice, bob, 41);
        assertEq(token.allowance(alice, spender), 100, "failed transfer consumed allowance");
        assertEq(token.balanceOf(alice), 40);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY - 60);
    }

    function testEntireSupplyCanBeBurnedAndNeverSpentAgain() public {
        assertTrue(token.transfer(alice, SUPPLY));
        vm.prank(alice);
        token.burn(SUPPLY);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.initialSupply(), SUPPLY);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.burn(1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(bob, 1);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.totalSupply(), 0);
    }

    function testFuzzSelfTransferPreservesBalanceAndDelegatedSelfTransferConsumesAllowance(
        uint256 balanceSeed,
        uint256 amountSeed
    ) public {
        uint256 held = bound(balanceSeed, 0, SUPPLY);
        uint256 amount = bound(amountSeed, 0, held);
        assertTrue(token.transfer(alice, held));
        vm.startPrank(alice);
        assertTrue(token.transfer(alice, amount));
        assertTrue(token.approve(spender, amount));
        vm.stopPrank();
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, alice, amount));
        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(address(this)), SUPPLY - held);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzzTransferAndBurnOverdrawRevertAtomically(uint256 balanceSeed, uint256 amountSeed) public {
        uint256 held = bound(balanceSeed, 0, SUPPLY);
        uint256 amount = bound(amountSeed, held + 1, type(uint256).max);
        assertTrue(token.transfer(alice, held));
        bytes memory reason =
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, amount);
        vm.expectRevert(reason);
        vm.prank(alice);
        token.transfer(bob, amount);
        vm.expectRevert(reason);
        vm.prank(alice);
        token.burn(amount);
        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY - held);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzzInsufficientAllowanceCannotMoveEvenOneExtraUnit(uint256 allowanceSeed, uint256 amountSeed) public {
        uint256 allowed = bound(allowanceSeed, 0, SUPPLY - 1);
        uint256 amount = bound(amountSeed, allowed + 1, SUPPLY);
        assertTrue(token.approve(spender, allowed));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
        );
        vm.prank(spender);
        token.transferFrom(address(this), bob, amount);
        assertEq(token.allowance(address(this), spender), allowed);
        _assertUntouchedSupply();
    }

    function testFuzzInsufficientBalanceRollsBackFiniteOrInfiniteAllowance(
        uint256 balanceSeed,
        uint256 amountSeed,
        bool infinite
    ) public {
        uint256 held = bound(balanceSeed, 0, SUPPLY);
        uint256 amount = bound(amountSeed, held + 1, type(uint256).max - 1);
        uint256 allowed = infinite ? type(uint256).max : amount;
        assertTrue(token.transfer(alice, held));
        vm.prank(alice);
        assertTrue(token.approve(spender, allowed));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, amount));
        vm.prank(spender);
        token.transferFrom(alice, bob, amount);
        assertEq(token.allowance(alice, spender), allowed);
        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY - held);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzzZeroRecipientRevertsWithoutConsumingAllowance(uint256 amountSeed, bool infinite) public {
        uint256 amount = bound(amountSeed, 0, SUPPLY);
        uint256 allowed = infinite ? type(uint256).max : amount;
        assertTrue(token.approve(spender, allowed));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(this), address(0), amount);
        assertEq(token.allowance(address(this), spender), allowed);
        _assertUntouchedSupply();
    }

    function testFuzzRepeatedDelegatedSpendsCannotExceedTheApprovedTotal(uint256 allowanceSeed, uint256 firstSeed)
        public
    {
        uint256 allowed = bound(allowanceSeed, 1, SUPPLY);
        uint256 first = bound(firstSeed, 0, allowed);
        assertTrue(token.approve(spender, allowed));
        vm.startPrank(spender);
        assertTrue(token.transferFrom(address(this), alice, first));
        assertTrue(token.transferFrom(address(this), bob, allowed - first));
        vm.stopPrank();
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(alice), first);
        assertEq(token.balanceOf(bob), allowed - first);
        assertEq(token.balanceOf(address(this)), SUPPLY - allowed);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), bob, 1);
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(bob), allowed - first);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function _assertUntouchedSupply() internal view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.initialSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.balanceOf(address(0)), 0);
    }
}
