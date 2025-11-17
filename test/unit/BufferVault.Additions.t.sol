// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";

import "../../contracts/vault/BufferVault.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MockERC20_BV_Add is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) { _mint(msg.sender, 1_000_000e18); }
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract BufferVaultAdditionalTests is Test {
    BufferVault public vault;
    BufferVault public implementation;
    MockERC20_BV_Add public token;

    address public admin;
    address public manager;
    address public funder;

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    function setUp() public {
        admin = makeAddr("admin");
        manager = makeAddr("manager");
        funder = makeAddr("funder");
        token = new MockERC20_BV_Add("USDC", "USDC");

        implementation = new BufferVault();
        vm.startPrank(admin);
        bytes memory initData = abi.encodeWithSelector(BufferVault.initialize.selector, makeAddr("config"), manager);
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = BufferVault(address(proxy));
        vault.setCap(address(token), type(uint256).max);
        vm.stopPrank();

        // Seed buffer
        token.mint(funder, 1_000e18);
        vm.startPrank(funder);
        token.approve(address(vault), type(uint256).max);
        vault.fund(address(token), 1_000e18);
        vm.stopPrank();
    }

    function testEmergencyDrainEmitsAndZeroesBalance() public {
        address to = makeAddr("to");
        uint256 bal = vault.getBalance(address(token));
        vm.prank(admin);
        vault.emergencyDrain(address(token), to);
        assertEq(vault.getBalance(address(token)), 0);
        assertEq(token.balanceOf(to), bal);
    }

    function testReceiveProceedsNoTransferNoOp() public {
        // Do not transfer tokens, call receiveProceeds with amount
        uint256 beforeBal = vault.getBalance(address(token));
        vm.prank(manager);
        vault.receiveProceeds(address(token), 123e18);
        // Balance should remain unchanged because actualBalance < expectedBalance
        assertEq(vault.getBalance(address(token)), beforeBal);
    }

    function testPauseBlocksCriticalFunctions() public {
        vm.prank(admin);
        vault.pause();
        assertTrue(vault.paused());

        // fund blocked
        vm.startPrank(funder);
        token.approve(address(vault), 1e18);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.fund(address(token), 1e18);
        vm.stopPrank();

        // spendTo blocked
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.spendTo(address(token), makeAddr("rcpt"), 1e18);

        // unpause
        vm.prank(admin);
        vault.unpause();
        assertFalse(vault.paused());
    }

    function testZeroAddressReverts() public {
        address rcpt = makeAddr("rcpt");

        // spendTo zero token
        vm.prank(manager);
        vm.expectRevert(Types.ZeroAddress.selector);
        vault.spendTo(address(0), rcpt, 1e18);

        // spendTo zero recipient
        vm.prank(manager);
        vm.expectRevert(Types.ZeroAddress.selector);
        vault.spendTo(address(token), address(0), 1e18);

        // receiveProceeds zero token
        vm.prank(manager);
        vm.expectRevert(Types.ZeroAddress.selector);
        vault.receiveProceeds(address(0), 1e18);

        // drain zero token
        vm.prank(admin);
        vm.expectRevert(Types.ZeroAddress.selector);
        vault.drain(address(0), rcpt, 1);

        // drain zero recipient
        vm.prank(admin);
        vm.expectRevert(Types.ZeroAddress.selector);
        vault.drain(address(token), address(0), 1);
    }
}
