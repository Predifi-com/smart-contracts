// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "../../../contracts/escrow/StagingEscrowVault.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("USDC", "USDC") {
        _mint(msg.sender, 1_000_000e18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract StagingEscrowVaultCoverageTest is Test {
    StagingEscrowVault public vault;
    StagingEscrowVault public implementation;
    MockERC20 public token;
    
    address public admin = address(0x1);
    address public operator = address(0x2);
    address public lpRecipient = address(0x3);
    address public feeRecipient = address(0x4);
    
    bytes32 public constant ADMIN_ROLE = 0x00; // DEFAULT_ADMIN_ROLE
    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE");
    bytes32 public constant SETTLEMENT_AUTHORITY_ROLE = keccak256("SETTLEMENT_AUTHORITY_ROLE");

    function setUp() public {
        token = new MockERC20();
        implementation = new StagingEscrowVault();
    }

    /// @dev Test initialize with zero admin (lines 52-56)
    function test_initialize_zero_admin() public {
        bytes memory initData = abi.encodeCall(
            StagingEscrowVault.initialize,
            (address(0))
        );
        
        vm.expectRevert("ZeroAdmin");
        new ERC1967Proxy(address(implementation), initData);
    }

    /// @dev Test release with fee transfer (line 116)
    function test_release_with_fee_transfer() public {
        bytes memory initData = abi.encodeCall(
            StagingEscrowVault.initialize,
            (admin)
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = StagingEscrowVault(address(proxy));
        
        vm.prank(admin);
        vault.grantRole(SETTLEMENT_AUTHORITY_ROLE, operator);
        
        // Setup reservation with fees
        bytes32 orderId = keccak256("order1");
        uint256 reserveAmount = 1000e18;
        uint256 reserveFee = 50e18;
        
        token.mint(operator, reserveAmount + reserveFee);
        
        vm.startPrank(operator);
            token.approve(address(vault), reserveAmount + reserveFee);
            vault.deposit(address(token), reserveAmount + reserveFee);
            vault.reserve(operator, orderId, address(token), reserveAmount, reserveFee, lpRecipient, feeRecipient, uint64(block.timestamp + 1 days));
        vm.stopPrank();
        
        uint256 lpBalanceBefore = token.balanceOf(lpRecipient);
        uint256 feeBalanceBefore = token.balanceOf(feeRecipient);
        
        // Release with larger amounts to trigger transfers
        vm.prank(operator);
        vault.releaseForOrder(orderId, reserveAmount, reserveFee);
        
        // Verify both LP and fee transfers occurred
        assertEq(token.balanceOf(lpRecipient) - lpBalanceBefore, reserveAmount);
        assertEq(token.balanceOf(feeRecipient) - feeBalanceBefore, reserveFee);
    }

    /// @dev Test pause functionality (line 147)
    function test_pause() public {
        bytes memory initData = abi.encodeCall(
            StagingEscrowVault.initialize,
            (admin)
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = StagingEscrowVault(address(proxy));
        
        vm.prank(admin);
        vault.pause();
        
        assertTrue(vault.paused());
    }

    /// @dev Test unpause functionality (line 148)
    function test_unpause() public {
        bytes memory initData = abi.encodeCall(
            StagingEscrowVault.initialize,
            (admin)
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = StagingEscrowVault(address(proxy));
        
        vm.prank(admin);
        vault.pause();
        
        vm.prank(admin);
        vault.unpause();
        
        assertFalse(vault.paused());
    }

    /// @dev Test _authorizeUpgrade (line 154)
    function test_authorizeUpgrade() public {
        bytes memory initData = abi.encodeCall(
            StagingEscrowVault.initialize,
            (admin)
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = StagingEscrowVault(address(proxy));
        
        StagingEscrowVault newImplementation = new StagingEscrowVault();
        
        vm.prank(admin);
        vault.upgradeToAndCall(address(newImplementation), "");
        
        // Verify upgrade worked by checking admin still has role
        assertTrue(vault.hasRole(ADMIN_ROLE, admin));
    }

    /// @dev Test release with partial amount and partial fee (lines 116)
    function test_release_partial_with_fees() public {
        bytes memory initData = abi.encodeCall(
            StagingEscrowVault.initialize,
            (admin)
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = StagingEscrowVault(address(proxy));
        
        vm.prank(admin);
        vault.grantRole(SETTLEMENT_AUTHORITY_ROLE, operator);
        
        bytes32 orderId = keccak256("order2");
        uint256 reserveAmount = 1000e18;
        uint256 reserveFee = 100e18;
        
        token.mint(operator, reserveAmount + reserveFee);
        
        vm.startPrank(operator);
            token.approve(address(vault), reserveAmount + reserveFee);
            vault.deposit(address(token), reserveAmount + reserveFee);
            vault.reserve(operator, orderId, address(token), reserveAmount, reserveFee, lpRecipient, feeRecipient, uint64(block.timestamp + 1 days));
        vm.stopPrank();
        
        uint256 lpBalanceBefore = token.balanceOf(lpRecipient);
        uint256 feeBalanceBefore = token.balanceOf(feeRecipient);
        
        // First release - partial
        vm.prank(operator);
        vault.releaseForOrder(orderId, 500e18, 50e18);
        
        uint256 lpAfterFirst = token.balanceOf(lpRecipient);
        uint256 feeAfterFirst = token.balanceOf(feeRecipient);
        
        assertEq(lpAfterFirst - lpBalanceBefore, 500e18);
        assertEq(feeAfterFirst - feeBalanceBefore, 50e18);
        
        // Second release - remaining
        vm.prank(operator);
        vault.releaseForOrder(orderId, 500e18, 50e18);
        
        uint256 lpAfterSecond = token.balanceOf(lpRecipient);
        uint256 feeAfterSecond = token.balanceOf(feeRecipient);
        
        // Verify additional transfers
        assertEq(lpAfterSecond - lpAfterFirst, 500e18);
        assertEq(feeAfterSecond - feeAfterFirst, 50e18);
    }

    /// @dev Test getReservation view function
    function test_getReservation() public {
        bytes memory initData = abi.encodeCall(
            StagingEscrowVault.initialize,
            (admin)
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = StagingEscrowVault(address(proxy));
        
        vm.prank(admin);
        vault.grantRole(SETTLEMENT_AUTHORITY_ROLE, operator);
        
        bytes32 orderId = keccak256("order3");
        uint256 reserveAmount = 500e18;
        uint256 reserveFee = 25e18;
        
        token.mint(operator, reserveAmount + reserveFee);
        
        vm.startPrank(operator);
        token.approve(address(vault), reserveAmount + reserveFee);
        vault.deposit(address(token), reserveAmount + reserveFee);
        vault.reserve(
            operator,
            orderId,
            address(token),
            reserveAmount,
            reserveFee,
            lpRecipient,
            feeRecipient,
            uint64(block.timestamp + 1 days)
        );
        vm.stopPrank();
        
        StagingEscrowVault.Reservation memory res = vault.getReservation(orderId);
        
        assertEq(res.asset, address(token));
        assertEq(res.reservedAmount, reserveAmount);
        assertEq(res.reservedFeeCap, reserveFee);
        assertEq(res.lpRecipient, lpRecipient);
        assertEq(res.feeRecipient, feeRecipient);
    }
}
