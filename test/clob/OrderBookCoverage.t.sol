// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../contracts/clob/core/MarketFactory.sol";
import "../../contracts/clob/core/OrderBook.sol";
import "../../contracts/clob/core/OracleAdapter.sol";
import "../../contracts/clob/libs/CLOBTypes.sol";
import "../../contracts/clob/libs/CLOBErrors.sol";

contract OrderBookCoverageTest is Test {
    MarketFactory public marketFactory;
    OrderBook public orderBook;
    OracleAdapter public oracleAdapter;

    address public admin;
    address public oracleSigner;
    uint256 public oracleSignerPk;
    address public user1;
    uint256 public user1Pk;
    address public user2;
    uint256 public user2Pk;

    function setUp() public {
        admin = makeAddr("admin");
        (oracleSigner, oracleSignerPk) = makeAddrAndKey("oracleSigner");
        (user1, user1Pk) = makeAddrAndKey("user1");
        (user2, user2Pk) = makeAddrAndKey("user2");

        // Oracle adapter
        OracleAdapter oracleImpl = new OracleAdapter();
        bytes memory oracleInitData = abi.encodeCall(
            OracleAdapter.initialize,
            (admin, oracleSigner, 1 hours)
        );
        ERC1967Proxy oracleProxy = new ERC1967Proxy(address(oracleImpl), oracleInitData);
        oracleAdapter = OracleAdapter(address(oracleProxy));

        // Market factory
        MarketFactory factoryImpl = new MarketFactory();
        bytes memory factoryInitData = abi.encodeCall(
            MarketFactory.initialize,
            (admin, address(oracleAdapter), 1 hours, 7 days)
        );
        ERC1967Proxy factoryProxy = new ERC1967Proxy(address(factoryImpl), factoryInitData);
        marketFactory = MarketFactory(address(factoryProxy));

        // OrderBook
        OrderBook orderBookImpl = new OrderBook();
        bytes memory orderBookInitData = abi.encodeCall(
            OrderBook.initialize,
            (admin, address(marketFactory))
        );
        ERC1967Proxy orderBookProxy = new ERC1967Proxy(address(orderBookImpl), orderBookInitData);
        orderBook = OrderBook(address(orderBookProxy));

    // Admin already has OPERATOR_ROLE via initialize; no extra grants needed
    }

    function _createMarket() internal returns (uint256 marketId, bytes32 conditionId) {
        conditionId = keccak256("ORDERBOOK_TEST");
        vm.prank(admin);
        marketId = marketFactory.createMarket(
            "OrderBook Test Market",
            block.timestamp + 2 days,
            block.timestamp + 4 days,
            conditionId,
            0
        );
    }

    function _signOrder(CLOBTypes.Order memory order, uint256 pk) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                orderBook.ORDER_TYPEHASH(),
                order.orderId,
                order.marketId,
                order.maker,
                uint8(order.side),
                order.price,
                order.size,
                order.nonce,
                order.expiry
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", orderBook.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_RevertPlaceOrder_InvalidPriceAndSizeAndExpiry() public {
        (uint256 marketId,) = _createMarket();
        // invalid size
        CLOBTypes.Order memory o = CLOBTypes.Order({
            orderId: 0,
            marketId: marketId,
            maker: user1,
            side: CLOBTypes.Side.BUY,
            price: 5000,
            size: 0,
            filled: 0,
            nonce: 0,
            expiry: block.timestamp + 1 hours,
            signature: ""
        });
        o.signature = _signOrder(o, user1Pk);
        vm.expectRevert(abi.encodeWithSelector(CLOBErrors.InvalidOrderSize.selector, 0));
        orderBook.placeOrder(o);

        // invalid price = 0
        o.size = 1;
        o.price = 0;
        o.signature = _signOrder(o, user1Pk);
        vm.expectRevert(abi.encodeWithSelector(CLOBErrors.InvalidOrderPrice.selector, 0));
        orderBook.placeOrder(o);

        // invalid price >= BPS_DIVISOR
        o.price = CLOBTypes.BPS_DIVISOR;
        o.signature = _signOrder(o, user1Pk);
        vm.expectRevert(abi.encodeWithSelector(CLOBErrors.InvalidOrderPrice.selector, CLOBTypes.BPS_DIVISOR));
        orderBook.placeOrder(o);

        // expired order
        o.price = 5000;
        o.expiry = block.timestamp; // <= now
        o.signature = _signOrder(o, user1Pk);
        vm.expectRevert(abi.encodeWithSelector(CLOBErrors.OrderExpired.selector, 0));
        orderBook.placeOrder(o);
    }

    function test_RevertPlaceOrder_InvalidSignature_AndNonceTooLow() public {
        (uint256 marketId,) = _createMarket();

        // Sign with wrong key -> InvalidSignature
        CLOBTypes.Order memory o = CLOBTypes.Order({
            orderId: 0,
            marketId: marketId,
            maker: user1,
            side: CLOBTypes.Side.SELL,
            price: 4000,
            size: 100,
            filled: 0,
            nonce: 0,
            expiry: block.timestamp + 1 hours,
            signature: ""
        });
        o.signature = _signOrder(o, user2Pk);
        vm.expectRevert(CLOBErrors.InvalidSignature.selector);
        orderBook.placeOrder(o);

        // Correct signature and place
        o.signature = _signOrder(o, user1Pk);
        uint256 orderId = orderBook.placeOrder(o);
        assertEq(orderId, 1);

        // Place again with same (lower) nonce -> OrderNonceTooLow
        o.expiry = block.timestamp + 2 hours;
        o.signature = _signOrder(o, user1Pk);
        vm.expectRevert(abi.encodeWithSelector(CLOBErrors.OrderNonceTooLow.selector, 0));
        orderBook.placeOrder(o);
    }

    function test_RevertPlaceOrder_MarketClosedPaths() public {
        (uint256 marketId, bytes32 conditionId) = _createMarket();

        // Warp to end -> MarketExpired in placeOrder
        vm.warp(block.timestamp + 2 days + 1);
        CLOBTypes.Order memory o = CLOBTypes.Order({
            orderId: 0,
            marketId: marketId,
            maker: user1,
            side: CLOBTypes.Side.BUY,
            price: 5000,
            size: 100,
            filled: 0,
            nonce: 0,
            expiry: block.timestamp + 1 hours,
            signature: ""
        });
        o.signature = _signOrder(o, user1Pk);
        vm.expectRevert(abi.encodeWithSelector(CLOBErrors.MarketExpired.selector, marketId));
        orderBook.placeOrder(o);

        // Reset with fresh market, then resolve it -> MarketAlreadyResolved in placeOrder
        (marketId, ) = _createMarket();
        vm.warp(block.timestamp + 3 days); // past end
        bytes memory sig = _signResolution(conditionId, CLOBTypes.Outcome.YES, block.timestamp, oracleSignerPk);
        CLOBTypes.ResolutionData memory resData = CLOBTypes.ResolutionData({
            marketId: marketId,
            conditionId: conditionId,
            outcome: CLOBTypes.Outcome.YES,
            timestamp: block.timestamp,
            oracleSignature: sig
        });
        vm.prank(admin);
        marketFactory.resolveMarket(marketId, resData);

        o.marketId = marketId;
        o.expiry = block.timestamp + 1 hours;
        o.signature = _signOrder(o, user1Pk);
        vm.expectRevert(abi.encodeWithSelector(CLOBErrors.MarketAlreadyResolved.selector, marketId));
        orderBook.placeOrder(o);

        // Reset with fresh market and pause -> MarketPaused in placeOrder
        (marketId, ) = _createMarket();
        vm.prank(admin);
        marketFactory.pauseMarket(marketId, true);
        o.marketId = marketId;
        o.signature = _signOrder(o, user1Pk);
        vm.expectRevert(abi.encodeWithSelector(CLOBErrors.MarketPaused.selector, marketId));
        orderBook.placeOrder(o);
    }

    function _signResolution(
        bytes32 conditionId,
        CLOBTypes.Outcome outcome,
        uint256 timestamp,
        uint256 privateKey
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                oracleAdapter.RESOLUTION_TYPEHASH(),
                conditionId,
                uint8(outcome),
                timestamp
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", oracleAdapter.domainSeparator(), structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_CancelOrder_Unauthorized_AlreadyCancelled() public {
        (uint256 marketId,) = _createMarket();
        CLOBTypes.Order memory o = CLOBTypes.Order({
            orderId: 0,
            marketId: marketId,
            maker: user1,
            side: CLOBTypes.Side.BUY,
            price: 5000,
            size: 100,
            filled: 0,
            nonce: 0,
            expiry: block.timestamp + 2 hours,
            signature: ""
        });
        o.signature = _signOrder(o, user1Pk);
        vm.prank(user1);
        uint256 oid = orderBook.placeOrder(o);

        // Unauthorized cancellation by user2
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(CLOBErrors.UnauthorizedCancellation.selector, user2, user1));
        orderBook.cancelOrder(oid);

        // Maker cancels
        vm.prank(user1);
        orderBook.cancelOrder(oid);

        // Cancel again -> OrderAlreadyFilled
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(CLOBErrors.OrderAlreadyFilled.selector, oid));
        orderBook.cancelOrder(oid);
    }

    function test_UpdateOrderFill_HappyAndInvalidFillSize() public {
        (uint256 marketId,) = _createMarket();
        CLOBTypes.Order memory o = CLOBTypes.Order({
            orderId: 0,
            marketId: marketId,
            maker: user1,
            side: CLOBTypes.Side.SELL,
            price: 4000,
            size: 1000,
            filled: 0,
            nonce: 0,
            expiry: block.timestamp + 2 hours,
            signature: ""
        });
        o.signature = _signOrder(o, user1Pk);
        vm.prank(user1);
        uint256 oid = orderBook.placeOrder(o);

    // Fill 600
    vm.prank(admin);
    orderBook.updateOrderFill(oid, 600);
        // Overfill by 500 (>remaining 400)
    vm.expectRevert(abi.encodeWithSelector(CLOBErrors.InvalidFillSize.selector, 500));
    vm.prank(admin);
    orderBook.updateOrderFill(oid, 500);
    }

    function test_IsOrderFillable_FalseStates() public {
        (uint256 marketId,) = _createMarket();
        CLOBTypes.Order memory o = CLOBTypes.Order({
            orderId: 0,
            marketId: marketId,
            maker: user1,
            side: CLOBTypes.Side.BUY,
            price: 5000,
            size: 100,
            filled: 0,
            nonce: 0,
            expiry: block.timestamp + 1 hours,
            signature: ""
        });
        o.signature = _signOrder(o, user1Pk);
        vm.prank(user1);
        uint256 oid = orderBook.placeOrder(o);

        // Expired
        vm.warp(block.timestamp + 2 hours);
        assertFalse(orderBook.isOrderFillable(oid));

    // Fresh order for other false states
        (marketId, ) = _createMarket();
        o.marketId = marketId;
    o.expiry = block.timestamp + 1 hours;
    o.nonce = 1; // increment to avoid OrderNonceTooLow
        o.signature = _signOrder(o, user1Pk);
        vm.prank(user1);
        oid = orderBook.placeOrder(o);

        // Cancelled
        vm.prank(user1);
        orderBook.cancelOrder(oid);
        assertFalse(orderBook.isOrderFillable(oid));

    // New order then pause market
        (marketId, ) = _createMarket();
        o.marketId = marketId;
    o.expiry = block.timestamp + 1 hours;
    o.nonce = 2;
        o.signature = _signOrder(o, user1Pk);
        vm.prank(user1);
        oid = orderBook.placeOrder(o);
        vm.prank(admin);
        marketFactory.pauseMarket(marketId, true);
        assertFalse(orderBook.isOrderFillable(oid));
    }

    function test_GetOrder_And_GetUserNonce_And_DomainSeparator() public {
        (uint256 marketId,) = _createMarket();
        CLOBTypes.Order memory o = CLOBTypes.Order({
            orderId: 0,
            marketId: marketId,
            maker: user1,
            side: CLOBTypes.Side.SELL,
            price: 4000,
            size: 100,
            filled: 0,
            nonce: 0,
            expiry: block.timestamp + 1 hours,
            signature: ""
        });
        o.signature = _signOrder(o, user1Pk);
        vm.prank(user1);
        uint256 oid = orderBook.placeOrder(o);

        CLOBTypes.Order memory stored = orderBook.getOrder(oid);
        assertEq(stored.price, 4000);
        assertEq(orderBook.getUserNonce(user1), 1);
        assertTrue(orderBook.domainSeparator() != bytes32(0));

        vm.expectRevert(abi.encodeWithSelector(CLOBErrors.OrderNotFound.selector, 9999));
        orderBook.getOrder(9999);
    }

    function test_Upgradeability_AuthorizeUpgrade() public {
        OrderBook newImpl = new OrderBook();
        vm.prank(admin);
        orderBook.upgradeToAndCall(address(newImpl), "");
        // Check marketFactory pointer unchanged
        assertEq(address(orderBook.marketFactory()), address(marketFactory));
    }
}
