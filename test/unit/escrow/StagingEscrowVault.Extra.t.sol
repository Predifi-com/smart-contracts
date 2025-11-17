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

contract StagingEscrowVaultExtraTest is Test {
    StagingEscrowVault public vault;
    MockERC20 public token;
    
    address public admin;
    address public operator;
    bytes32 public constant SETTLEMENT_AUTHORITY_ROLE = keccak256("SETTLEMENT_AUTHORITY_ROLE");

    function setUp() public {
        admin = address(this);
        operator = address(0x2);
        token = new MockERC20();
    }

    /// @dev Test complete initialization flow to cover lines 53-56
    function test_full_initialization() public {
        StagingEscrowVault implementation = new StagingEscrowVault(); // Covers line 48
        
        bytes memory initData = abi.encodeCall(
            StagingEscrowVault.initialize,
            (admin)
        );
        
        // This should cover lines 52-59
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = StagingEscrowVault(address(proxy));
        
        // Verify initialization worked - this execution path covers __UUPSUpgradeable_init, etc.
        assertTrue(vault.hasRole(vault.ADMIN_ROLE(), admin));
        assertTrue(vault.hasRole(vault.PAUSE_ROLE(), admin));
        assertFalse(vault.paused());
    }

    /// @dev Multiple sequential initializations to ensure constructor coverage
    function test_multiple_deployments() public {
        for (uint i = 0; i < 3; i++) {
            StagingEscrowVault impl = new StagingEscrowVault();
            bytes memory data = abi.encodeCall(StagingEscrowVault.initialize, (admin));
            new ERC1967Proxy(address(impl), data);
        }
    }

    /// @dev Test releaseForOrder with ONLY fee delta (amount delta = 0) to cover line 119
    function test_releaseForOrder_only_fee() public {
        StagingEscrowVault implementation = new StagingEscrowVault();
        bytes memory initData = abi.encodeCall(
            StagingEscrowVault.initialize,
            (admin)
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = StagingEscrowVault(address(proxy));
        
    vault.grantRole(SETTLEMENT_AUTHORITY_ROLE, operator);
        
        // Setup reservation
        bytes32 orderId = keccak256("order1");
        uint256 reserveAmount = 1000e18;
        uint256 reserveFee = 100e18;
        
        token.mint(operator, reserveAmount + reserveFee);
        vm.startPrank(operator);
        token.approve(address(vault), reserveAmount + reserveFee);
        vault.deposit(address(token), reserveAmount + reserveFee);
        vault.reserve(operator, orderId, address(token), reserveAmount, reserveFee, address(0x123), address(0x456), uint64(block.timestamp + 1 days));
        
        // Release ONLY fee (amount = 0)
        uint256 feeRecipientBefore = token.balanceOf(address(0x456));
        vault.releaseForOrder(orderId, 0, reserveFee);
        vm.stopPrank();
        
        // Verify only fee was transferred (line 119)
        assertEq(token.balanceOf(address(0x456)) - feeRecipientBefore, reserveFee);
    }

    /// @dev Test releaseForOrder with ONLY amount delta (fee delta = 0) to cover line 116
    function test_releaseForOrder_only_amount() public {
        StagingEscrowVault implementation = new StagingEscrowVault();
        bytes memory initData = abi.encodeCall(
            StagingEscrowVault.initialize,
            (admin)
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = StagingEscrowVault(address(proxy));
        
        vault.grantRole(SETTLEMENT_AUTHORITY_ROLE, operator);
        
        // Setup reservation
        bytes32 orderId = keccak256("order2");
        uint256 reserveAmount = 1000e18;
        uint256 reserveFee = 100e18;
        
        token.mint(operator, reserveAmount + reserveFee);
        vm.startPrank(operator);
        token.approve(address(vault), reserveAmount + reserveFee);
        vault.deposit(address(token), reserveAmount + reserveFee);
        vault.reserve(operator, orderId, address(token), reserveAmount, reserveFee, address(0x123), address(0x456), uint64(block.timestamp + 1 days));
        
        // Release ONLY amount (fee = 0)
        uint256 lpRecipientBefore = token.balanceOf(address(0x123));
        vault.releaseForOrder(orderId, reserveAmount, 0);
        vm.stopPrank();
        
        // Verify only amount was transferred (line 116)
        assertEq(token.balanceOf(address(0x123)) - lpRecipientBefore, reserveAmount);
    }
}
