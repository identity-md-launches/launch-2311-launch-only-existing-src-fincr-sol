// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {FINCR} from "../src/FINCR.sol";

/// @notice Offline regressions for the FINCR-only custom token launch.
/// @dev This test contract models the constructor caller, not the official factory implementation.
/// Other labeled actors model transfer endpoints only; they are not deployment configuration.
contract FINCRLaunchTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    bytes32 internal constant CREATION_WITH_ARGS_HASH =
        0x511ed126a50c2e98030294c73314bb5b42beb62bbc2a87848e2bc44abddf7562;
    bytes32 internal constant RUNTIME_HASH = 0x946270e19519507b25f0e64ba542b050d325476e1a397aadf1f64ea23d16064c;
    address internal constant REMAINDER_TO = 0xbcF19c0821A245383c127570615896Abac9e424F;

    FINCR internal token;
    address internal holder;
    address internal stranger;

    function setUp() public {
        vm.chainId(4663);
        holder = makeAddr("FINCR test holder");
        stranger = makeAddr("FINCR test stranger");
        token = new FINCR{salt: keccak256("FINCR test salt")}(SUPPLY);
    }

    function testPinnedCreationAndDeployedRuntime() public view {
        bytes memory initCode = abi.encodePacked(type(FINCR).creationCode, abi.encode(SUPPLY));
        assertEq(keccak256(initCode), CREATION_WITH_ARGS_HASH);
        assertEq(keccak256(address(token).code), RUNTIME_HASH);
        assertLe(address(token).code.length, 24_576);
    }

    function testMetadataAndWholeSupplyMintedToFactoryCaller() public view {
        assertEq(token.name(), "FINANCIER");
        assertEq(token.symbol(), "FINCR");
        assertEq(token.decimals(), 18);
        assertEq(token.initialSupply(), 1000000000000000000000000000);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(REMAINDER_TO), 0);
    }

    function testConstructorMintsToCallerInsteadOfTransactionOrigin() public {
        vm.prank(holder, stranger);
        FINCR other = new FINCR(SUPPLY);
        assertEq(other.balanceOf(holder), SUPPLY);
        assertEq(other.balanceOf(stranger), 0);
        assertEq(other.balanceOf(address(this)), 0);
        assertEq(keccak256(address(other).code), RUNTIME_HASH);
    }

    /// @dev Reproduces imported audit finding b4a313ce: intentional validation, not a defect.
    function testConstructorRejectsZeroAndNonDivisibleSupply() public {
        vm.expectRevert(bytes("invalid supply"));
        new FINCR(0);
        vm.expectRevert(bytes("invalid supply"));
        new FINCR(SUPPLY + 1);
    }

    function testFuzzConstructorRejectsNonDivisibleSupply(uint256 supply) public {
        vm.assume(supply % 100 != 0);
        vm.expectRevert(bytes("invalid supply"));
        new FINCR(supply);
    }

    /// @dev Preserve the original constructor, including valid inputs other than the launch amount.
    /// Only SUPPLY is authorized for this launch; the creation hash also binds that argument.
    function testFuzzConstructorAcceptsPositiveMultiplesOf100(uint256 seed) public {
        uint256 supply = bound(seed, 1, type(uint256).max / 100) * 100;
        FINCR other = new FINCR(supply);
        assertEq(other.initialSupply(), supply);
        assertEq(other.totalSupply(), supply);
        assertEq(other.balanceOf(address(this)), supply);
    }

    function testLaunchAllocationsAndSwarmClaimArriveWhole() public {
        address distributor = makeAddr("FINCR test distributor");
        address poolManager = makeAddr("FINCR test pool manager");
        uint256 swarm = SUPPLY / 10;
        uint256 pool = SUPPLY / 2;
        uint256 remainder = SUPPLY - swarm - pool;

        // Model token transfers in factory order, without deploying application contracts.
        assertTrue(token.transfer(distributor, swarm));
        assertTrue(token.transfer(poolManager, pool));
        assertTrue(token.transfer(REMAINDER_TO, remainder));
        assertEq(token.balanceOf(distributor), 100_000_000 ether);
        assertEq(token.balanceOf(poolManager), 500_000_000 ether);
        assertEq(token.balanceOf(REMAINDER_TO), 400_000_000 ether);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.totalSupply(), SUPPLY);

        vm.prank(distributor);
        assertTrue(token.transfer(holder, swarm));
        assertEq(token.balanceOf(distributor), 0);
        assertEq(token.balanceOf(holder), swarm);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Checks the token's buy/sell transfer legs, not pool pricing or v4 unlock/settlement.
    function testPoolTransfersArriveWholeInBothDirections() public {
        address poolManager = makeAddr("FINCR test pool manager");
        assertTrue(token.transfer(poolManager, SUPPLY / 2));
        vm.prank(poolManager);
        assertTrue(token.transfer(holder, 1 ether));
        assertEq(token.balanceOf(holder), 1 ether);
        assertEq(token.balanceOf(poolManager), SUPPLY / 2 - 1 ether);
        vm.prank(holder);
        assertTrue(token.transfer(poolManager, 1 ether));
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(poolManager), SUPPLY / 2);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testVoluntaryBurnAndOverdrawRevert() public {
        assertTrue(token.transfer(holder, 1 ether));
        vm.prank(holder);
        token.burn(0.4 ether);
        assertEq(token.balanceOf(holder), 0.6 ether);
        assertEq(token.totalSupply(), SUPPLY - 0.4 ether);
        assertEq(token.initialSupply(), SUPPLY);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, 0.6 ether, 0.6 ether + 1)
        );
        vm.prank(holder);
        token.burn(0.6 ether + 1);
        assertEq(token.balanceOf(holder), 0.6 ether);
        assertEq(token.totalSupply(), SUPPLY - 0.4 ether);
    }

    function testFuzzTransferAndVoluntaryBurnConserveSupply(uint256 transferSeed, uint256 burnSeed) public {
        uint256 transferred = bound(transferSeed, 0, SUPPLY);
        uint256 burned = bound(burnSeed, 0, transferred);
        assertTrue(token.transfer(holder, transferred));
        vm.prank(holder);
        token.burn(burned);
        assertEq(token.balanceOf(address(this)), SUPPLY - transferred);
        assertEq(token.balanceOf(holder), transferred - burned);
        assertEq(token.totalSupply(), SUPPLY - burned);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(holder), token.totalSupply());
        assertEq(token.initialSupply(), SUPPLY);
    }

    function testFactoryNeedsHolderAllowanceAndCannotOverspendIt() public {
        assertTrue(token.transfer(holder, 1 ether));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(holder, address(this), 1);
        assertEq(token.balanceOf(holder), 1 ether);

        vm.prank(holder);
        assertTrue(token.approve(address(this), 0.4 ether));
        assertTrue(token.transferFrom(holder, address(this), 0.4 ether));
        assertEq(token.allowance(holder, address(this)), 0);
        assertEq(token.balanceOf(holder), 0.6 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(holder, address(this), 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFactoryAndStrangerHaveNoMintAdminOrFreezePowers() public {
        assertTrue(token.transfer(holder, 1 ether));
        bytes[] memory calls = new bytes[](22);
        calls[0] = abi.encodeWithSignature("mint(address,uint256)", stranger, 1);
        calls[1] = abi.encodeWithSignature("mint(uint256)", 1);
        calls[2] = abi.encodeWithSignature("mint()");
        calls[3] = abi.encodeWithSignature("issue(uint256)", 1);
        calls[4] = abi.encodeWithSignature("setOwner(address)", stranger);
        calls[5] = abi.encodeWithSignature("transferOwnership(address)", stranger);
        calls[6] = abi.encodeWithSignature("upgradeTo(address)", stranger);
        calls[7] = abi.encodeWithSignature("initialize(address)", stranger);
        calls[8] = abi.encodeWithSignature("unpause()");
        calls[9] = abi.encodeWithSignature("setMinter(address)", stranger);
        calls[10] = abi.encodeWithSignature("pause()");
        calls[11] = abi.encodeWithSignature("blacklist(address)", holder);
        calls[12] = abi.encodeWithSignature("blocklist(address)", holder);
        calls[13] = abi.encodeWithSignature("freeze(address)", holder);
        calls[14] = abi.encodeWithSignature("freezeAccount(address)", holder);
        calls[15] = abi.encodeWithSignature("setBlacklist(address,bool)", holder, true);
        calls[16] = abi.encodeWithSignature("setBlocked(address,bool)", holder, true);
        calls[17] = abi.encodeWithSignature("lock(address)", holder);
        calls[18] = abi.encodeWithSignature("disableTransfers()");
        calls[19] = abi.encodeWithSignature("setTransfersEnabled(bool)", false);
        calls[20] = abi.encodeWithSignature("burnFrom(address,uint256)", holder, 1);
        calls[21] = abi.encodeWithSignature("seize(address)", holder);
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(token).call(calls[i]);
            assertFalse(ok, "constructor caller reached a privileged selector");
            vm.prank(stranger);
            (ok,) = address(token).call(calls[i]);
            assertFalse(ok, "stranger reached a privileged selector");
            assertEq(token.totalSupply(), SUPPLY);
            assertEq(token.balanceOf(holder), 1 ether);
            assertEq(token.balanceOf(stranger), 0);
        }
        vm.prank(holder);
        assertTrue(token.transfer(stranger, 1 ether));
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(stranger), 1 ether);
    }

    function testRuntimeContainsNoForbiddenOpcodes() public view {
        bytes memory runtime = address(token).code;
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4, "DELEGATECALL");
            assertTrue(op != 0xf2, "CALLCODE");
            assertTrue(op != 0xff, "SELFDESTRUCT");
        }
    }
}
