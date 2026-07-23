// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {LPVault} from "../src/vault/LPVault.sol";

contract MockStable is ERC20 {
    constructor() ERC20("Mock Stable", "mUSD") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract LPVaultTest is Test {
    MockStable stable;
    LPVault vault;

    address admin = address(0xA11CE);
    address alice = address(0xA71CE);
    address bob = address(0xB0B);

    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
    event Paused(address account);
    event Unpaused(address account);

    function setUp() public {
        stable = new MockStable();
        LPVault implementation = new LPVault();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(LPVault.initialize, (stable, "Predifi Stable Vault", "pSTABLE", admin))
        );
        vault = LPVault(payable(address(proxy)));

        stable.mint(alice, 1_000_000e6);
        stable.mint(bob, 1_000_000e6);

        vm.prank(alice);
        stable.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        stable.approve(address(vault), type(uint256).max);
    }

    function testDepositMintsSharesAndEmitsEvent() public {
        uint256 assets = 1_000e6;
        uint256 expectedShares = vault.previewDeposit(assets);

        vm.expectEmit(true, true, false, true);
        emit Deposit(alice, alice, assets, expectedShares);

        vm.prank(alice);
        uint256 shares = vault.deposit(assets, alice);

        assertEq(shares, expectedShares);
        assertEq(vault.totalAssets(), assets);
        assertEq(stable.balanceOf(address(vault)), assets);
        assertEq(vault.balanceOf(alice), expectedShares);
    }

    function testWithdrawBurnsSharesAndEmitsEvent() public {
        uint256 assets = 1_000e6;
        vm.prank(alice);
        vault.deposit(assets, alice);

        uint256 expectedShares = vault.previewWithdraw(250e6);

        vm.expectEmit(true, true, true, true);
        emit Withdraw(alice, alice, alice, 250e6, expectedShares);

        vm.prank(alice);
        uint256 burned = vault.withdraw(250e6, alice, alice);

        assertEq(burned, expectedShares);
        assertEq(vault.totalAssets(), 750e6);
        assertEq(stable.balanceOf(alice), 999_250e6);
    }

    function testPauseBlocksDepositAndWithdrawThenUnpauseRestores() public {
        vm.expectEmit(false, false, false, true);
        emit Paused(admin);
        vm.prank(admin);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(1e6, alice);

        vm.expectEmit(false, false, false, true);
        emit Unpaused(admin);
        vm.prank(admin);
        vault.unpause();

        vm.prank(alice);
        vault.deposit(1e6, alice);
        assertEq(vault.totalAssets(), 1e6);
    }

    function testOnlyPauserCanPause() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.pause();
    }

    function testAdminRoleChangesAreAuditable() public {
        bytes32 pauserRole = vault.PAUSER_ROLE();

        vm.prank(admin);
        vault.grantRole(pauserRole, bob);

        assertTrue(vault.hasRole(pauserRole, bob));

        vm.prank(bob);
        vault.pause();
        assertTrue(vault.paused());
    }
}
