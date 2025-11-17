// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "../../../contracts/config/TreasurySplitter.sol";
import "../../../contracts/libs/Types.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract TreasurySplitterTest is Test {
    TreasurySplitter public splitter;
    MockERC20 public token;
    address public admin;
    address public distributor;
    address public r1;
    address public r2;

    function setUp() public {
        admin = address(this);
        distributor = makeAddr("distributor");
        r1 = makeAddr("r1");
        r2 = makeAddr("r2");

    TreasurySplitter impl = new TreasurySplitter();
    ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(TreasurySplitter.initialize, (admin, distributor)));
    splitter = TreasurySplitter(address(proxy));

        token = new MockERC20();
    }

    function testConfigureRecipientsAndDistributeDefault() public {
        // Configure default recipients (sum <= 10000)
        splitter.configureDefaultRecipient(r1, 6000, true, "ops");
        splitter.configureDefaultRecipient(r2, 4000, true, "treasury");

        // Fund distributor and approve splitter
        uint256 amount = 1_000_000e6; // assume 6 decimals scenario; ERC20 here 18 but amounts arbitrary
        token.mint(distributor, amount);
        vm.prank(distributor);
        token.approve(address(splitter), amount);

        // Send fees via receiveFees (auto-distribute on receive is enabled by default)
        vm.prank(distributor);
        splitter.receiveFees(address(token), amount);

        // Totals tracked
        assertEq(splitter.totalFeesReceived(address(token)), amount);
        // Distribution recorded
    uint256 d1 = splitter.distributedToRecipient(address(token), r1);
    uint256 d2 = splitter.distributedToRecipient(address(token), r2);
    assertEq(d1 + d2, splitter.totalFeesDistributed(address(token)));
    // Basis split by 60/40
    assertEq(d1, (amount * 6000) / 10000);
    assertEq(d2, (amount * 4000) / 10000);
    }

    function testTokenSpecificRecipientsOverrideAndManualDistribute() public {
        // Configure token-specific recipients
        splitter.configureTokenRecipient(address(token), r1, 7000, true, "ops");
        splitter.configureTokenRecipient(address(token), r2, 3000, true, "treasury");

        // Disable auto-distribute to test manual path
        splitter.updateDistributionSettings(1, false);

        uint256 amount = 5e18;
        token.mint(address(splitter), amount); // directly fund splitter to test manual distribute

        uint256 distributed = splitter.distributeFees(address(token));
        assertEq(distributed, amount);
        assertEq(splitter.totalFeesDistributed(address(token)), amount);
        assertEq(splitter.distributedToRecipient(address(token), r1), (amount * 7000) / 10000);
        assertEq(splitter.distributedToRecipient(address(token), r2), (amount * 3000) / 10000);
    }

    function testInvalidConfigsAndLimits() public {
        // Invalid basis points
        vm.expectRevert(Types.InvalidBasisPoints.selector);
        splitter.configureDefaultRecipient(r1, 10001, true, "bad");

        // Too many recipients: add up to MAX_RECIPIENTS then expect revert on next
        for (uint256 i = 0; i < 20; i++) {
            address recipient = makeAddr(string(abi.encodePacked("rcp", vm.toString(i))));
            // Keep total basis within 10000 by adding small shares and toggling active
            splitter.configureDefaultRecipient(recipient, 1, true, "x");
        }
        vm.expectRevert(Types.TooManyRecipients.selector);
        splitter.configureDefaultRecipient(makeAddr("overflow"), 1, true, "x");

        // Emergency withdraw guards
        vm.expectRevert(Types.ZeroAddress.selector);
        splitter.emergencyWithdraw(address(token), address(0), 1);
        vm.expectRevert(Types.InvalidAmount.selector);
        splitter.emergencyWithdraw(address(token), admin, 0);
    }

    function testDustRemainderGoesToFirstActiveRoute() public {
        // Configure three recipients with totals < 10000 to force dust
        splitter.configureDefaultRecipient(r1, 3333, true, "A");
        splitter.configureDefaultRecipient(r2, 3333, true, "B");
        address r3 = makeAddr("r3");
        splitter.configureDefaultRecipient(r3, 3333, true, "C");

        // Fund distributor and distribute an amount that will produce dust
        uint256 amount = 100; // small amount to show remainder
        token.mint(distributor, amount);
        vm.startPrank(distributor);
        token.approve(address(splitter), amount);
        // Lower threshold so auto-distribution triggers
        vm.stopPrank();
        splitter.updateDistributionSettings(1, true);
        vm.startPrank(distributor);
        splitter.receiveFees(address(token), amount);
        vm.stopPrank();

        // First active route gets extra dust
        uint256 expected = (amount * 3333) / 10000;
        uint256 d1 = splitter.distributedToRecipient(address(token), r1);
        uint256 d2 = splitter.distributedToRecipient(address(token), r2);
        uint256 d3 = splitter.distributedToRecipient(address(token), r3);
        assertTrue(d1 >= expected);
        assertEq(d2, expected);
        assertEq(d3, expected);
        assertEq(d1 + d2 + d3, splitter.totalFeesDistributed(address(token)));
    }

    function testCanDistributeViewAndGetters() public {
        // No recipients configured -> cannot distribute
        assertFalse(splitter.canDistribute(address(token)));

        // Configure token-specific recipient; fund contract
        splitter.configureTokenRecipient(address(token), r1, 5000, true, "X");
        token.mint(address(splitter), 1e18);
        assertTrue(splitter.canDistribute(address(token)));

        // Getter coverage
        assertEq(splitter.getTotalBasisPoints(address(token)), 5000);
        TreasurySplitter.FeeRecipient[] memory tr = splitter.getTokenRecipients(address(token));
        assertEq(tr.length, 1);
        assertEq(tr[0].recipient, r1);
        assertEq(tr[0].basisPoints, 5000);

        // Default getters
        TreasurySplitter.FeeRecipient[] memory dr = splitter.getDefaultRecipients();
        assertEq(dr.length, 0);
        assertEq(splitter.getDistributableAmount(address(token)), token.balanceOf(address(splitter)));
        assertEq(splitter.getRecipientShare(address(token), r1), 5000);
    }

    function testRecipientUpdatesAndDistributeNoConfigAndEmergencyWithdraw() public {
        // No recipients configured anywhere -> distributeFees returns 0
        token.mint(address(splitter), 1000);
        assertEq(splitter.distributeFees(address(token)), 0);

        // Configure, then update recipients (both token-specific and default)
        splitter.configureTokenRecipient(address(token), r1, 2000, true, "x");
        // Update existing to inactive
        splitter.configureTokenRecipient(address(token), r1, 0, false, "x");
        assertEq(splitter.getRecipientShare(address(token), r1), 0);

        splitter.configureDefaultRecipient(r1, 4000, true, "a");
        // Update existing default recipient
        splitter.configureDefaultRecipient(r1, 3000, true, "b");
        TreasurySplitter.FeeRecipient[] memory dr = splitter.getDefaultRecipients();
        assertEq(dr[0].basisPoints, 3000);

        // Balance below minimum -> canDistribute false
        splitter.updateDistributionSettings(1e18, true);
        assertFalse(splitter.canDistribute(address(token)));

        // Emergency withdraw success path
        uint256 bal = token.balanceOf(address(splitter));
        address to = makeAddr("to");
        uint256 withdrawAmt = bal;
        splitter.emergencyWithdraw(address(token), to, withdrawAmt);
        assertEq(token.balanceOf(to), withdrawAmt);
    }
}
