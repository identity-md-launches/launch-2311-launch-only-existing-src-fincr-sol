// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {FINCR} from "src/FINCR.sol";

/// @notice Drives only FINCR, using a closed set of local actors and independent accounting.
/// @dev These roles model token transfer endpoints, not the official launch infrastructure.
/// Ghost balances are initialized from the requested allocation and updated from call inputs,
/// never copied from balanceOf/allowance after a call. No deal/store/mint shortcut funds actors.
contract FINCRHandler is Test {
    uint256 public constant SUPPLY = 1_000_000_000 ether;
    uint256 public constant ACTOR_COUNT = 6;
    FINCR public immutable token;
    address[6] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    uint256 public burned;
    uint256 public positiveTransfers;
    uint256 public positiveDelegatedTransfers;
    uint256 public rejectedCalls;

    constructor() {
        actors[0] = address(this); // The constructor caller models the factory.
        actors[1] = makeAddr("FINCR invariant swarm endpoint");
        actors[2] = makeAddr("FINCR invariant pool endpoint");
        actors[3] = makeAddr("FINCR invariant founder endpoint");
        actors[4] = makeAddr("FINCR invariant trader one");
        actors[5] = makeAddr("FINCR invariant trader two");
        token = new FINCR(SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertTrue(token.transfer(actors[1], SUPPLY / 10));
        assertTrue(token.transfer(actors[2], SUPPLY / 2));
        assertTrue(token.transfer(actors[3], SUPPLY * 4 / 10));
        expectedBalance[actors[1]] = SUPPLY / 10;
        expectedBalance[actors[2]] = SUPPLY / 2;
        expectedBalance[actors[3]] = SUPPLY * 4 / 10;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 amount = bound(amountSeed, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
        if (amount != 0) ++positiveTransfers;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        // Retain the full uint256 domain: approvals may legitimately exceed the total supply.
        _approve(owner, spender, amount);
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowed = expectedAllowance[owner][spender];
        uint256 available = expectedBalance[owner];
        uint256 amount = bound(amountSeed, 0, allowed < available ? allowed : available);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        expectedBalance[owner] -= amount;
        expectedBalance[to] += amount;
        if (allowed != type(uint256).max) expectedAllowance[owner][spender] -= amount;
        if (amount != 0) ++positiveDelegatedTransfers;
    }

    function burn(uint256 ownerSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        uint256 amount = bound(amountSeed, 0, expectedBalance[owner]);
        vm.prank(owner);
        token.burn(amount);
        expectedBalance[owner] -= amount;
        burned += amount;
    }

    function rejectOverdraw(uint256 ownerSeed, uint256 amountSeed, bool burning) external {
        address owner = _actor(ownerSeed);
        uint256 held = expectedBalance[owner];
        uint256 amount = bound(amountSeed, held + 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, held, amount));
        vm.prank(owner);
        if (burning) token.burn(amount);
        else token.transfer(_actor((ownerSeed % ACTOR_COUNT) + 1), amount);
        ++rejectedCalls;
    }

    function revokeAndRejectSpend(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        _approve(owner, spender, 0);
        uint256 amount = bound(amountSeed, 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, amount));
        vm.prank(spender);
        token.transferFrom(owner, _actor(toSeed), amount);
        ++rejectedCalls;
    }

    function rejectOverdrawnDelegatedSpend(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed, bool infinite)
        external
    {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 held = expectedBalance[owner];
        uint256 amount = bound(amountSeed, held + 1, type(uint256).max - 1);
        _approve(owner, spender, infinite ? type(uint256).max : amount);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, held, amount));
        vm.prank(spender);
        token.transferFrom(owner, spender, amount);
        ++rejectedCalls;
    }

    function rejectZeroRecipient(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed, bool delegated) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 limit = expectedBalance[owner];
        uint256 allowed = expectedAllowance[owner][spender];
        if (delegated && allowed < limit) limit = allowed;
        uint256 amount = bound(amountSeed, 0, limit);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(delegated ? spender : owner);
        if (delegated) token.transferFrom(owner, address(0), amount);
        else token.transfer(address(0), amount);
        ++rejectedCalls;
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % ACTOR_COUNT];
    }
}
