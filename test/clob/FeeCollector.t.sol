// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../../contracts/clob/core/FeeCollector.sol";
import "../../contracts/clob/libs/CLOBTypes.sol";
import "../../contracts/clob/libs/CLOBErrors.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {
        _mint(msg.sender, 1000000 * 10**6);
    }
    
    function decimals() public pure override returns (uint8) {
        return 6;
    }
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FeeCollectorTest is Test {
    FeeCollector public implementation;
    FeeCollector public feeCollector;
    MockERC20 public usdc;
    
    address public admin;
    address public feeManager;
    address public settlement;
    address public feeRecipient;
    address public user1;
    address public user2;
    
    function setUp() public {
        admin = makeAddr("admin");
        feeManager = makeAddr("feeManager");
        settlement = makeAddr("settlement");
        feeRecipient = makeAddr("feeRecipient");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        
        // Deploy mock USDC
        usdc = new MockERC20();
        
        // Deploy implementation
        implementation = new FeeCollector();
        
        // Deploy proxy and initialize
        bytes memory initData = abi.encodeCall(
            FeeCollector.initialize,
            (admin, address(usdc), feeRecipient)
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            initData
        );
        
        feeCollector = FeeCollector(address(proxy));
        
        // Grant roles
        vm.startPrank(admin);
        feeCollector.grantRole(feeCollector.FEE_MANAGER_ROLE(), feeManager);
        feeCollector.grantRole(feeCollector.SETTLEMENT_ROLE(), settlement);
        vm.stopPrank();
        
        // Mint USDC to user1
        usdc.mint(user1, 10000 * 10**6);
    }
    
    function testInitialization() public view {
        assertTrue(feeCollector.hasRole(feeCollector.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(feeCollector.hasRole(feeCollector.FEE_MANAGER_ROLE(), feeManager));
        assertTrue(feeCollector.hasRole(feeCollector.SETTLEMENT_ROLE(), settlement));
        
        CLOBTypes.FeeConfig memory config = feeCollector.getFeeConfig();
        assertEq(config.defaultFeeBps, CLOBTypes.DEFAULT_FEE_BPS);
        assertEq(config.maxFeeBps, CLOBTypes.MAX_FEE_BPS);
        assertEq(config.feeRecipient, feeRecipient);
    }
    
    function testCollectFee() public {
        uint256 marketId = 1;
        uint256 winningAmount = 10000 * 10**6; // 10k USDC
        uint256 expectedFee = (winningAmount * 200) / 10000; // 2%
        
        vm.prank(user1);
        usdc.approve(address(feeCollector), expectedFee);
        
        vm.expectEmit(true, true, false, true);
        emit IFeeCollector.FeeCollected(marketId, user1, expectedFee, 200);
        
        vm.prank(settlement);
        uint256 fee = feeCollector.collectFee(marketId, user1, winningAmount);
        
        assertEq(fee, expectedFee);
        assertEq(feeCollector.marketFees(marketId), expectedFee);
        assertEq(feeCollector.totalFeesCollected(), expectedFee);
        assertEq(usdc.balanceOf(address(feeCollector)), expectedFee);
    }
    
    function testCollectFeeZeroAmount() public {
        vm.prank(settlement);
        uint256 fee = feeCollector.collectFee(1, user1, 0);
        
        assertEq(fee, 0);
    }
    
    function testCollectFeeMultipleMarkets() public {
        uint256 amount1 = 5000 * 10**6;
        uint256 amount2 = 8000 * 10**6;
        uint256 fee1 = (amount1 * 200) / 10000;
        uint256 fee2 = (amount2 * 200) / 10000;
        
        vm.prank(user1);
        usdc.approve(address(feeCollector), fee1 + fee2);
        
        vm.startPrank(settlement);
        feeCollector.collectFee(1, user1, amount1);
        feeCollector.collectFee(2, user1, amount2);
        vm.stopPrank();
        
        assertEq(feeCollector.marketFees(1), fee1);
        assertEq(feeCollector.marketFees(2), fee2);
        assertEq(feeCollector.totalFeesCollected(), fee1 + fee2);
    }
    
    function testCannotCollectFeeWithoutRole() public {
        vm.expectRevert();
        vm.prank(user1);
        feeCollector.collectFee(1, user1, 1000 * 10**6);
    }
    
    function testWithdrawFees() public {
        // First collect some fees
        uint256 amount = 10000 * 10**6;
        uint256 fee = (amount * 200) / 10000;
        
        vm.prank(user1);
        usdc.approve(address(feeCollector), fee);
        
        vm.prank(settlement);
        feeCollector.collectFee(1, user1, amount);
        
        // Withdraw fees
        uint256 withdrawAmount = fee / 2;
        
        vm.expectEmit(true, false, false, true);
        emit IFeeCollector.FeeWithdrawn(feeRecipient, withdrawAmount);
        
        vm.prank(feeManager);
        feeCollector.withdrawFees(feeRecipient, withdrawAmount);
        
        assertEq(usdc.balanceOf(feeRecipient), withdrawAmount);
        assertEq(feeCollector.totalFeesCollected(), fee - withdrawAmount);
    }
    
    function testCannotWithdrawMoreThanCollected() public {
        uint256 excessAmount = 1000 * 10**6;
        
        vm.expectRevert(
            abi.encodeWithSelector(
                CLOBErrors.InsufficientBalance.selector,
                excessAmount,
                0
            )
        );
        vm.prank(feeManager);
        feeCollector.withdrawFees(feeRecipient, excessAmount);
    }
    
    function testCannotWithdrawToZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(CLOBErrors.ZeroAddress.selector));
        vm.prank(feeManager);
        feeCollector.withdrawFees(address(0), 100);
    }
    
    function testCannotWithdrawZeroAmount() public {
        vm.expectRevert(abi.encodeWithSelector(CLOBErrors.ZeroAmount.selector));
        vm.prank(feeManager);
        feeCollector.withdrawFees(feeRecipient, 0);
    }
    
    function testCannotWithdrawWithoutRole() public {
        vm.expectRevert();
        vm.prank(user1);
        feeCollector.withdrawFees(feeRecipient, 100);
    }
    
    function testUpdateFeeConfig() public {
        uint16 newDefault = 300; // 3%
        uint16 newMax = 400;     // 4%
        
        vm.expectEmit(false, false, false, true);
        emit IFeeCollector.FeeConfigUpdated(newDefault, newMax);
        
        vm.prank(feeManager);
        feeCollector.updateFeeConfig(newDefault, newMax);
        
        CLOBTypes.FeeConfig memory config = feeCollector.getFeeConfig();
        assertEq(config.defaultFeeBps, newDefault);
        assertEq(config.maxFeeBps, newMax);
    }
    
    function testCannotUpdateFeeConfigDefaultTooHigh() public {
        vm.expectRevert(
            abi.encodeWithSelector(CLOBErrors.FeeTooHigh.selector, 600, 500)
        );
        vm.prank(feeManager);
        feeCollector.updateFeeConfig(600, 500);
    }
    
    function testCannotUpdateFeeConfigMaxAbsoluteLimit() public {
        vm.expectRevert(
            abi.encodeWithSelector(CLOBErrors.FeeTooHigh.selector, 600, CLOBTypes.MAX_FEE_BPS)
        );
        vm.prank(feeManager);
        feeCollector.updateFeeConfig(100, 600);
    }
    
    function testCannotUpdateFeeConfigWithoutRole() public {
        vm.expectRevert();
        vm.prank(user1);
        feeCollector.updateFeeConfig(300, 400);
    }
    
    function testUpdateFeeRecipient() public {
        address newRecipient = makeAddr("newRecipient");
        
        vm.prank(feeManager);
        feeCollector.updateFeeRecipient(newRecipient);
        
        CLOBTypes.FeeConfig memory config = feeCollector.getFeeConfig();
        assertEq(config.feeRecipient, newRecipient);
    }
    
    function testCannotUpdateFeeRecipientToZero() public {
        vm.expectRevert(
            abi.encodeWithSelector(CLOBErrors.InvalidFeeRecipient.selector, address(0))
        );
        vm.prank(feeManager);
        feeCollector.updateFeeRecipient(address(0));
    }
    
    function testCalculateFee() public view {
        uint256 amount = 10000 * 10**6;
        uint256 expected = (amount * 200) / 10000;
        
        uint256 fee = feeCollector.calculateFee(amount);
        assertEq(fee, expected);
    }

    function testCalculateFeeZero() public view {
        assertEq(feeCollector.calculateFee(0), 0);
    }
    
    function testFuzzCollectFee(uint256 amount, uint16 feeBps) public {
        amount = bound(amount, 1, 1000000 * 10**6);
        feeBps = uint16(bound(feeBps, 1, CLOBTypes.MAX_FEE_BPS));
        
        // Update fee config
        vm.prank(feeManager);
        feeCollector.updateFeeConfig(feeBps, CLOBTypes.MAX_FEE_BPS);
        
        uint256 expectedFee = (amount * feeBps) / 10000;
        
        usdc.mint(user1, expectedFee);
        vm.prank(user1);
        usdc.approve(address(feeCollector), expectedFee);
        
        vm.prank(settlement);
        uint256 fee = feeCollector.collectFee(1, user1, amount);
        
        assertEq(fee, expectedFee);
    }
    
    function testMarketFeesTracking() public {
        uint256 amount = 10000 * 10**6;
        uint256 expectedFee = (amount * 200) / 10000;
        
        usdc.mint(user1, expectedFee);
        vm.prank(user1);
        usdc.approve(address(feeCollector), expectedFee);
        
        vm.prank(settlement);
        feeCollector.collectFee(1, user1, amount);
        
        assertEq(feeCollector.marketFees(1), expectedFee);
        assertEq(feeCollector.totalFeesCollected(), expectedFee);
    }
    
    function testMultipleMarketsTracking() public {
        uint256 amount1 = 10000 * 10**6;
        uint256 amount2 = 5000 * 10**6;
        uint256 fee1 = (amount1 * 200) / 10000;
        uint256 fee2 = (amount2 * 200) / 10000;
        
        usdc.mint(user1, fee1 + fee2);
        vm.prank(user1);
        usdc.approve(address(feeCollector), fee1 + fee2);
        
        vm.startPrank(settlement);
        feeCollector.collectFee(1, user1, amount1);
        feeCollector.collectFee(2, user1, amount2);
        vm.stopPrank();
        
        assertEq(feeCollector.marketFees(1), fee1);
        assertEq(feeCollector.marketFees(2), fee2);
        assertEq(feeCollector.totalFeesCollected(), fee1 + fee2);
    }
    
    function testCollectFeeAccumulatesTotal() public {
        uint256 amount1 = 10000 * 10**6;
        uint256 amount2 = 8000 * 10**6;
        uint256 fee1 = (amount1 * 200) / 10000;
        uint256 fee2 = (amount2 * 200) / 10000;
        
        usdc.mint(user1, fee1);
        vm.prank(user1);
        usdc.approve(address(feeCollector), fee1);
        
        vm.prank(settlement);
        feeCollector.collectFee(1, user1, amount1);
        
        assertEq(feeCollector.totalFeesCollected(), fee1);
        
        usdc.mint(user2, fee2);
        vm.prank(user2);
        usdc.approve(address(feeCollector), fee2);
        
        vm.prank(settlement);
        feeCollector.collectFee(1, user2, amount2);
        
        assertEq(feeCollector.totalFeesCollected(), fee1 + fee2);
        assertEq(feeCollector.marketFees(1), fee1 + fee2);
    }

    function testCollectFeeRevertsOnZeroFrom() public {
        vm.prank(settlement);
        vm.expectRevert(CLOBErrors.ZeroAddress.selector);
        feeCollector.collectFee(1, address(0), 1);
    }
    
    function testWithdrawFeesReducesAvailableBalance() public {
        uint256 amount = 10000 * 10**6;
        uint256 fee = (amount * 200) / 10000;
        
        usdc.mint(user1, fee);
        vm.prank(user1);
        usdc.approve(address(feeCollector), fee);
        
        vm.prank(settlement);
        feeCollector.collectFee(1, user1, amount);
        
        uint256 totalBefore = feeCollector.totalFeesCollected();
        assertEq(totalBefore, fee);
        
        uint256 recipientBalanceBefore = usdc.balanceOf(feeRecipient);
        
        vm.prank(feeManager);
        feeCollector.withdrawFees(feeRecipient, fee);
        
        // Fees withdrawn from contract
        assertEq(usdc.balanceOf(feeRecipient), recipientBalanceBefore + fee);
        assertEq(usdc.balanceOf(address(feeCollector)), 0);
    }

    function testUpdateFeeRecipientRequiresRole() public {
        address newRecipient = makeAddr("newFeeRecipient");
        vm.expectRevert();
        vm.prank(user1);
        feeCollector.updateFeeRecipient(newRecipient);
    }

    function testUUPSUpgrade_AuthorizedAndUnauthorized() public {
        // Unauthorized upgrade attempt by non-admin
        FeeCollector newImpl = new FeeCollector();
        vm.expectRevert();
        vm.prank(user1);
        feeCollector.upgradeToAndCall(address(newImpl), "");

        // Authorized by admin
        vm.prank(admin);
        feeCollector.upgradeToAndCall(address(newImpl), "");
        // Basic sanity: state remains intact (collateral token and fee config)
        assertEq(address(feeCollector.collateralToken()), address(usdc));
        CLOBTypes.FeeConfig memory cfg = feeCollector.getFeeConfig();
        assertEq(cfg.feeRecipient, feeRecipient);
    }

    function testInitialize_RevertOnZeroAddresses() public {
        // zero admin
        FeeCollector impl = new FeeCollector();
        bytes memory initData1 = abi.encodeCall(FeeCollector.initialize, (address(0), address(usdc), feeRecipient));
        vm.expectRevert(CLOBErrors.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), initData1);

        // zero collateral token
        bytes memory initData2 = abi.encodeCall(FeeCollector.initialize, (admin, address(0), feeRecipient));
        vm.expectRevert(CLOBErrors.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), initData2);
    }

    function testInitialize_RevertOnInvalidFeeRecipient() public {
        FeeCollector impl = new FeeCollector();
        bytes memory initData = abi.encodeCall(FeeCollector.initialize, (admin, address(usdc), address(0)));
        vm.expectRevert(abi.encodeWithSelector(CLOBErrors.InvalidFeeRecipient.selector, address(0)));
        new ERC1967Proxy(address(impl), initData);
    }
}
