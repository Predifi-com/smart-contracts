// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "../../../contracts/config/ProtocolConfig.sol";
import "../../../contracts/libs/Types.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract ProtocolConfigAdditionalTests is Test {
    ProtocolConfig public config;
    address public admin;
    address public pauser;

    function setUp() public {
        admin = makeAddr("admin");
        pauser = makeAddr("pauser");

        ProtocolConfig impl = new ProtocolConfig();
        Types.ProtocolParams memory initial = Types.ProtocolParams({
            minBetAmount: 1,
            maxBetAmount: 1_000_000,
            maxIntentDuration: 7 days,
            baseFeeRate: 30,
            maxFeeRate: 1000,
            treasuryFeeRate: 200,
            lpYieldRate: 100
        });
        // Deploy via UUPS proxy
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(ProtocolConfig.initialize, (initial)));
        config = ProtocolConfig(address(proxy));
    // grant pause role to pauser
    config.grantRole(config.PAUSE_ROLE(), pauser);
    }

    function testUpdateProtocolParamsAndInvalids() public {
        Types.ProtocolParams memory bad = Types.ProtocolParams({
            minBetAmount: 100,
            maxBetAmount: 50,
            maxIntentDuration: 7 days,
            baseFeeRate: 30,
            maxFeeRate: 1000,
            treasuryFeeRate: 200,
            lpYieldRate: 100
        });
        vm.expectRevert(Types.InvalidAmount.selector);
        config.updateProtocolParams(bad);

        bad = Types.ProtocolParams({
            minBetAmount: 1,
            maxBetAmount: 2,
            maxIntentDuration: 0,
            baseFeeRate: 30,
            maxFeeRate: 1000,
            treasuryFeeRate: 200,
            lpYieldRate: 100
        });
        vm.expectRevert(Types.InvalidDuration.selector);
        config.updateProtocolParams(bad);

        bad = Types.ProtocolParams({
            minBetAmount: 1,
            maxBetAmount: 2,
            maxIntentDuration: 1,
            baseFeeRate: 10001,
            maxFeeRate: 1000,
            treasuryFeeRate: 200,
            lpYieldRate: 100
        });
        vm.expectRevert(Types.InvalidFeeRate.selector);
        config.updateProtocolParams(bad);
    }

    function testSetChainConfigAndVenueAndTokens() public {
        Types.ChainConfig memory c = Types.ChainConfig({ messengerAdapter: address(0), enabled: true });
        vm.expectRevert(Types.ZeroAddress.selector);
        config.setChainConfig(1, c);

        c.messengerAdapter = makeAddr("msgr");
        config.setChainConfig(1, c);
        assertTrue(config.isChainSupported(1));

        Types.VenueConfig memory v = Types.VenueConfig({
            traderSafe: makeAddr("safe"),
            bufferVault: makeAddr("buf"),
            useBufferVault: true,
            enabled: true
        });
        config.setVenueConfig(1, v);
        assertTrue(config.isVenueEnabled(1));

        address token = makeAddr("usdc");
        config.setTokenConfig(token, 10, true);
        assertTrue(config.isTokenSupported(token));
    }

    function testPauseFlagsAffectOperational() public {
        // set chain and venue enabled
        Types.ChainConfig memory c = Types.ChainConfig({ messengerAdapter: makeAddr("m"), enabled: true });
        config.setChainConfig(137, c);
        config.setVenueEnabled(137, true);
        assertTrue(config.isOperational(137));

        vm.prank(pauser);
        config.setGlobalEmergencyPause(true);
        assertFalse(config.isOperational(137));
    }

    function testEnableDisableChainAndVenueAndViews() public {
        // Initially unsupported
        assertFalse(config.isChainSupported(100));
        assertFalse(config.isVenueEnabled(100));

    // Enable flags even before configs; these booleans are checked directly
    config.setChainEnabled(100, true);
    config.setVenueEnabled(100, true);
    assertTrue(config.isChainSupported(100));
    assertTrue(config.isVenueEnabled(100));

        // Set configs
        Types.ChainConfig memory cc = Types.ChainConfig({ messengerAdapter: makeAddr("m"), enabled: true });
        config.setChainConfig(100, cc);
        Types.VenueConfig memory vc = Types.VenueConfig({
            traderSafe: makeAddr("safe"),
            bufferVault: address(0),
            useBufferVault: false,
            enabled: true
        });
        config.setVenueConfig(100, vc);

        assertTrue(config.isChainSupported(100));
        assertTrue(config.isVenueEnabled(100));

        // Batch getters
        uint256[] memory ids = new uint256[](2);
        ids[0] = 100; ids[1] = 101;
        Types.ChainConfig[] memory ccs = config.getChainConfigs(ids);
        Types.VenueConfig[] memory vcs = config.getVenueConfigs(ids);
        assertEq(ccs.length, 2);
        assertEq(vcs.length, 2);

        // Hash retrieval non-zero
        bytes32 h = config.getConfigHash(100);
        assertTrue(h != bytes32(0));

        // Toggle enabled flags after configs exist to cover event branches
        config.setChainEnabled(100, false);
        assertFalse(config.isChainSupported(100));
        config.setVenueEnabled(100, false);
        assertFalse(config.isVenueEnabled(100));

        // Chain emergency pause disables regardless of support flag
        config.setChainEnabled(100, true);
        assertTrue(config.isChainSupported(100));
        config.setChainEmergencyPause(100, true);
        assertFalse(config.isChainSupported(100));
    }

    function testPauseUnpauseAndRoleRestrictions() public {
        // Non-pauser cannot pause
        address notPauser = makeAddr("np");
        vm.prank(notPauser);
        vm.expectRevert();
        config.pause();

        // Grant PAUSE_ROLE to test address and toggle
        config.grantRole(config.PAUSE_ROLE(), address(this));
        config.pause();
        assertTrue(config.paused());
        config.unpause();
        assertFalse(config.paused());
    }

    function testRevertValidationsAndEvents() public {
        // setChainConfig reverts
        Types.ChainConfig memory c = Types.ChainConfig({ messengerAdapter: address(0), enabled: true });
        vm.expectRevert(Types.ZeroAddress.selector);
        config.setChainConfig(1, c);
        c.messengerAdapter = makeAddr("m");
        vm.expectEmit(true, true, true, true);
        emit ProtocolConfig.ChainConfigUpdated(1, c, 1);
        config.setChainConfig(1, c);

        // setVenueConfig reverts
        Types.VenueConfig memory v = Types.VenueConfig({
            traderSafe: address(0), bufferVault: address(0), useBufferVault: false, enabled: true
        });
        vm.expectRevert(Types.ZeroAddress.selector);
        config.setVenueConfig(1, v);
        v.traderSafe = makeAddr("safe");
        vm.expectEmit(true, true, true, true);
        emit ProtocolConfig.VenueConfigUpdated(1, v);
        config.setVenueConfig(1, v);

        // setTokenConfig reverts and emits
        address token = makeAddr("tkn");
        vm.expectRevert(Types.ZeroAddress.selector);
        config.setTokenConfig(address(0), 1, true);
        vm.expectEmit(true, true, true, true);
        emit ProtocolConfig.TokenConfigUpdated(token, 5, true);
        config.setTokenConfig(token, 5, true);
        assertEq(config.getTokenMinAmount(token), 5);
        assertTrue(config.isTokenSupported(token));

        // Emergency pause events
        vm.expectEmit(true, true, true, true);
        emit ProtocolConfig.GlobalEmergencyPauseToggled(true);
        config.setGlobalEmergencyPause(true);
        vm.expectEmit(true, true, true, true);
        emit ProtocolConfig.EmergencyPauseToggled(1, true);
        config.setChainEmergencyPause(1, true);
    }

    function testGettersAndEmergencyAffectsVenue() public {
        // Initialize configs
        Types.ProtocolParams memory pp = config.getProtocolParams();
        assertGt(pp.maxBetAmount, 0);

        uint256 id = 42;
        Types.ChainConfig memory cc = Types.ChainConfig({ messengerAdapter: makeAddr("m"), enabled: true });
        Types.VenueConfig memory vc = Types.VenueConfig({ traderSafe: makeAddr("s"), bufferVault: address(0), useBufferVault: false, enabled: true });
        config.setChainConfig(id, cc);
        config.setVenueConfig(id, vc);

        // Emergency pause on chain disables venue
        config.setChainEmergencyPause(id, true);
        assertFalse(config.isVenueEnabled(id));

        // Getters for structs
        Types.ChainConfig memory cc2 = config.getChainConfig(id);
        Types.VenueConfig memory vc2 = config.getVenueConfig(id);
        assertEq(cc2.messengerAdapter, cc.messengerAdapter);
        assertEq(vc2.traderSafe, vc.traderSafe);
    }
}
