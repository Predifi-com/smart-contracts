// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/*
 Disabled: Outdated ProtocolConfig tests intentionally excluded from current coverage
 The active tests for deployable contracts are in other files.
*/
/*
    emit TokenConfigUpdated(token, minAmount, true);
        
        vm.prank(configAdmin);
        config.setTokenConfig(token, minAmount, true);
        
        assertEq(config.tokenMinAmounts(token), minAmount);
        assertTrue(config.supportedTokens(token));
    }

    function testSetTokenConfigZeroAddress() public {
        vm.prank(configAdmin);
        vm.expectRevert(Types.ZeroAddress.selector);
        config.setTokenConfig(address(0), 10e18, true);
    }

    function testSetTokenConfigMultipleTokens() public {
        for (uint256 i = 1; i <= 5; i++) {
            address token = makeAddr(string(abi.encodePacked("token", i)));
            
            vm.prank(configAdmin);
            config.setTokenConfig(token, i * 10e18, true);
            
            assertEq(config.tokenMinAmounts(token), i * 10e18);
            assertTrue(config.supportedTokens(token));
        }
    }

    function testSetTokenConfigDisableToken() public {
        address token = makeAddr("usdc");
        
        vm.startPrank(configAdmin);
        config.setTokenConfig(token, 10e18, true);
        config.setTokenConfig(token, 10e18, false);
        vm.stopPrank();
        
        assertFalse(config.supportedTokens(token));
    }

    // Emergency pause tests
    function testSetChainEmergencyPauseSuccess() public {
        uint256 chainId = 1;
        
        vm.expectEmit(true, true, true, true);
        emit EmergencyPauseToggled(chainId, true);
        
        vm.prank(pauseAdmin);
        config.setChainEmergencyPause(chainId, true);
        
        assertTrue(config.chainEmergencyPause(chainId));
    }

    function testSetChainEmergencyPauseUnauthorized() public {
        vm.prank(user);
        vm.expectRevert();
        config.setChainEmergencyPause(1, true);
    }

    function testSetGlobalEmergencyPauseSuccess() public {
        vm.expectEmit(true, true, true, true);
        emit GlobalEmergencyPauseToggled(true);
        
        vm.prank(pauseAdmin);
        config.setGlobalEmergencyPause(true);
        
        assertTrue(config.globalEmergencyPause());
    }

    function testSetGlobalEmergencyPauseUnpause() public {
        vm.startPrank(pauseAdmin);
        config.setGlobalEmergencyPause(true);
        config.setGlobalEmergencyPause(false);
        vm.stopPrank();
        
        assertFalse(config.globalEmergencyPause());
    }

    // Enable/disable tests
    function testSetChainEnabledSuccess() public {
        uint256 chainId = 1;
        
        // First set chain config
        Types.ChainConfig memory chainConfig = Types.ChainConfig({
            messengerAdapter: makeAddr("messenger"),
            enabled: true
        });
        
        vm.startPrank(configAdmin);
        config.setChainConfig(chainId, chainConfig);
        
        // Now disable it
        config.setChainEnabled(chainId, false);
        vm.stopPrank();
        
        assertFalse(config.supportedChains(chainId));
    }

    function testSetVenueEnabledSuccess() public {
        uint256 chainId = 1;
        
        // First set venue config
        Types.VenueConfig memory venueConfig = Types.VenueConfig({
            traderSafe: makeAddr("traderSafe"),
            bufferVault: makeAddr("bufferVault"),
            useBufferVault: true,
            enabled: true
        });
        
        vm.startPrank(configAdmin);
        config.setVenueConfig(chainId, venueConfig);
        
        // Now disable it
        config.setVenueEnabled(chainId, false);
        vm.stopPrank();
        
        assertFalse(config.enabledVenues(chainId));
    }

    // View function tests
    function testGetProtocolParams() public view {
        (uint256 min, uint256 max, uint256 duration, uint256 baseFee, uint256 maxFee, uint256 treasuryFee, uint256 lpYield) = 
            config.protocolParams();
        
        assertEq(min, initialParams.minBetAmount);
        assertEq(max, initialParams.maxBetAmount);
        assertEq(duration, initialParams.maxIntentDuration);
        assertEq(baseFee, initialParams.baseFeeRate);
        assertEq(maxFee, initialParams.maxFeeRate);
        assertEq(treasuryFee, initialParams.treasuryFeeRate);
        assertEq(lpYield, initialParams.lpYieldRate);
    }

    function testConfigVersionIncrementsOnUpdate() public {
        assertEq(config.configVersion(), 1);
        
        vm.prank(configAdmin);
        config.updateProtocolParams(initialParams);
        
        assertEq(config.configVersion(), 2);
    }

    function testChainConfigVersionIncrementsOnUpdate() public {
        uint256 chainId = 1;
        Types.ChainConfig memory chainConfig = Types.ChainConfig({
            messengerAdapter: makeAddr("messenger"),
            enabled: true
        });
        
        vm.startPrank(configAdmin);
        config.setChainConfig(chainId, chainConfig);
        assertEq(config.chainConfigVersions(chainId), 1);
        
        config.setChainConfig(chainId, chainConfig);
        assertEq(config.chainConfigVersions(chainId), 2);
        vm.stopPrank();
    }

    // Edge cases
    function testSetChainConfigMaxChainId() public {
        uint256 maxChainId = type(uint64).max;
        Types.ChainConfig memory chainConfig = Types.ChainConfig({
            messengerAdapter: makeAddr("messenger"),
            enabled: true
        });
        
        vm.prank(configAdmin);
        config.setChainConfig(maxChainId, chainConfig);
        
        assertTrue(config.supportedChains(maxChainId));
    }

    function testSetTokenConfigZeroMinAmount() public {
        address token = makeAddr("usdc");
        
        vm.prank(configAdmin);
        config.setTokenConfig(token, 0, true);
        
        assertEq(config.tokenMinAmounts(token), 0);
        assertTrue(config.supportedTokens(token));
    }

    function testUpdateProtocolParamsEqualMinMax() public {
        Types.ProtocolParams memory newParams = initialParams;
        newParams.minBetAmount = 100e18;
        newParams.maxBetAmount = 100e18;
        
        vm.prank(configAdmin);
        config.updateProtocolParams(newParams);
        
        (uint256 min, uint256 max,,,,,,) = config.protocolParams();
        assertEq(min, max);
    }

    function testMultipleEmergencyPauseToggles() public {
        uint256 chainId = 1;
        
        vm.startPrank(pauseAdmin);
        config.setChainEmergencyPause(chainId, true);
        assertTrue(config.chainEmergencyPause(chainId));
        
        config.setChainEmergencyPause(chainId, false);
        assertFalse(config.chainEmergencyPause(chainId));
        
        config.setChainEmergencyPause(chainId, true);
        assertTrue(config.chainEmergencyPause(chainId));
        vm.stopPrank();
    }
}
*/
