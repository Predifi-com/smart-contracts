// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../../contracts/clob/core/MarketFactory.sol";
import "../../contracts/clob/core/OrderBook.sol";
import "../../contracts/clob/core/Settlement.sol";
import "../../contracts/clob/core/OracleAdapter.sol";
import "../../contracts/clob/core/FeeCollector.sol";
import "../../contracts/clob/tokens/YesNoToken.sol";
import "../../contracts/clob/libs/CLOBTypes.sol";
import "../../contracts/clob/libs/CLOBErrors.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract SettlementCoverageTest is Test {
    MarketFactory public marketFactory;
    OrderBook public orderBook;
    Settlement public settlement;
    OracleAdapter public oracleAdapter;
    FeeCollector public feeCollector;
    YesNoToken public yesNoToken;
    MockUSDC public usdc;

    address public admin;
    address public oracleSigner;
    uint256 public oracleSignerPk;
    address public user1;
    uint256 public user1Pk;
    address public user2;
    uint256 public user2Pk;
    address public settler;
    address public feeRecipient;

    uint256 constant INITIAL_USDC = 100000 * 10**6;

    function setUp() public {
        admin = makeAddr("admin");
        (oracleSigner, oracleSignerPk) = makeAddrAndKey("oracleSigner");
        (user1, user1Pk) = makeAddrAndKey("user1");
        (user2, user2Pk) = makeAddrAndKey("user2");
        settler = makeAddr("settler");
        feeRecipient = makeAddr("feeRecipient");

        // Deploy USDC
        usdc = new MockUSDC();
        usdc.mint(user1, INITIAL_USDC);
        usdc.mint(user2, INITIAL_USDC);

        // YesNoToken
        YesNoToken yesNoImpl = new YesNoToken();
        bytes memory yesNoInit = abi.encodeCall(YesNoToken.initialize, (admin, "ipfs://yesno/{id}"));
        ERC1967Proxy yesNoProxy = new ERC1967Proxy(address(yesNoImpl), yesNoInit);
        yesNoToken = YesNoToken(address(yesNoProxy));

        // OracleAdapter
        OracleAdapter oracleImpl = new OracleAdapter();
        bytes memory oracleInit = abi.encodeCall(OracleAdapter.initialize, (admin, oracleSigner, 1 hours));
        ERC1967Proxy oracleProxy = new ERC1967Proxy(address(oracleImpl), oracleInit);
        oracleAdapter = OracleAdapter(address(oracleProxy));

        // FeeCollector
        FeeCollector feeImpl = new FeeCollector();
        bytes memory feeInit = abi.encodeCall(FeeCollector.initialize, (admin, address(usdc), feeRecipient));
        ERC1967Proxy feeProxy = new ERC1967Proxy(address(feeImpl), feeInit);
        feeCollector = FeeCollector(address(feeProxy));

        // MarketFactory
        MarketFactory factoryImpl = new MarketFactory();
        bytes memory factoryInit = abi.encodeCall(MarketFactory.initialize, (admin, address(oracleAdapter), 1 hours, 7 days));
        ERC1967Proxy factoryProxy = new ERC1967Proxy(address(factoryImpl), factoryInit);
        marketFactory = MarketFactory(address(factoryProxy));

        // OrderBook
        OrderBook orderImpl = new OrderBook();
        bytes memory orderInit = abi.encodeCall(OrderBook.initialize, (admin, address(marketFactory)));
        ERC1967Proxy orderProxy = new ERC1967Proxy(address(orderImpl), orderInit);
        orderBook = OrderBook(address(orderProxy));

        // Settlement
        Settlement settlementImpl = new Settlement();
        bytes memory settlementInit = abi.encodeCall(Settlement.initialize, (admin, address(marketFactory), address(orderBook), address(yesNoToken), address(feeCollector), address(usdc)));
        ERC1967Proxy settlementProxy = new ERC1967Proxy(address(settlementImpl), settlementInit);
        settlement = Settlement(address(settlementProxy));

        // Roles
        vm.startPrank(admin);
        yesNoToken.grantRole(yesNoToken.MINTER_ROLE(), address(settlement));
        feeCollector.grantRole(feeCollector.SETTLEMENT_ROLE(), address(settlement));
        orderBook.grantRole(orderBook.OPERATOR_ROLE(), address(settlement));
        orderBook.grantRole(orderBook.OPERATOR_ROLE(), settler);
        settlement.grantRole(settlement.SETTLER_ROLE(), settler);
        vm.stopPrank();
    }

    function _createMarket(bytes32 conditionId) internal returns (uint256) {
        vm.prank(admin);
        return marketFactory.createMarket(
            "Settlement Test Market",
            block.timestamp + 1 days,
            block.timestamp + 2 days,
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

    function _signResolution(bytes32 conditionId, CLOBTypes.Outcome outcome, uint256 timestamp, uint256 pk) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(oracleAdapter.RESOLUTION_TYPEHASH(), conditionId, uint8(outcome), timestamp));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", oracleAdapter.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _placeOrder(uint256 marketId, address maker, uint256 pk, CLOBTypes.Side side, uint256 price, uint256 size) internal returns (uint256) {
        CLOBTypes.Order memory o = CLOBTypes.Order({
            orderId: 0,
            marketId: marketId,
            maker: maker,
            side: side,
            price: price,
            size: size,
            filled: 0,
            nonce: orderBook.getUserNonce(maker),
            expiry: block.timestamp + 1 hours,
            signature: ""
        });
        o.signature = _signOrder(o, pk);
        vm.prank(maker);
        return orderBook.placeOrder(o);
    }

    function test_DepositWithdrawCollateral_EdgeCases() public {
        uint256 marketId = _createMarket(keccak256("DEP_WITHDRAW"));

        // deposit zero
        vm.expectRevert(CLOBErrors.ZeroAmount.selector);
        settlement.depositCollateral(marketId, 0);

        // withdraw zero
        vm.expectRevert(CLOBErrors.ZeroAmount.selector);
        settlement.withdrawCollateral(marketId, 0);

        // deposit valid
        vm.prank(user1);
        usdc.approve(address(settlement), 1000);
        vm.prank(user1);
        settlement.depositCollateral(marketId, 1000);

        // withdraw exceeding
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(CLOBErrors.InsufficientCollateral.selector, 2000, 1000));
        settlement.withdrawCollateral(marketId, 2000);

        // partial withdraw
        vm.prank(user1);
        settlement.withdrawCollateral(marketId, 400);
        // full withdraw remaining
        vm.prank(user1);
        settlement.withdrawCollateral(marketId, 600);
    }

    function test_SettleTrade_Reverts_On_MarketStates() public {
        bytes32 cond = keccak256("MARKET_STATE");
        uint256 marketId = _createMarket(cond);
        // Pause -> revert
        vm.prank(admin);
        marketFactory.pauseMarket(marketId, true);
        CLOBTypes.Fill memory fill = CLOBTypes.Fill({
            orderId: 1,
            marketId: marketId,
            maker: user1,
            taker: user2,
            makerSide: CLOBTypes.Side.BUY,
            price: 5000,
            size: 1000,
            timestamp: block.timestamp
        });
        vm.prank(settler);
        vm.expectRevert(abi.encodeWithSelector(CLOBErrors.MarketPaused.selector, marketId));
        settlement.settleTrade(fill);

        // Resolve -> revert MarketAlreadyResolved
        marketId = _createMarket(cond);
        vm.warp(block.timestamp + 2 days);
        bytes memory sig = _signResolution(cond, CLOBTypes.Outcome.YES, block.timestamp, oracleSignerPk);
        CLOBTypes.ResolutionData memory resData = CLOBTypes.ResolutionData({
            marketId: marketId,
            conditionId: cond,
            outcome: CLOBTypes.Outcome.YES,
            timestamp: block.timestamp,
            oracleSignature: sig
        });
        vm.prank(admin);
        marketFactory.resolveMarket(marketId, resData);

        fill.marketId = marketId;
        vm.prank(settler);
        vm.expectRevert(abi.encodeWithSelector(CLOBErrors.MarketAlreadyResolved.selector, marketId));
        settlement.settleTrade(fill);

        // Expired -> revert
        marketId = _createMarket(cond);
        vm.warp(block.timestamp + 1 days + 1);
        fill.marketId = marketId;
        vm.prank(settler);
        vm.expectRevert(abi.encodeWithSelector(CLOBErrors.MarketExpired.selector, marketId));
        settlement.settleTrade(fill);
    }

    function test_SettleTrade_Reverts_OrderChecks() public {
        uint256 marketId = _createMarket(keccak256("ORDER_CHECKS"));
        // place valid order
        uint256 orderId = _placeOrder(marketId, user1, user1Pk, CLOBTypes.Side.BUY, 6000, 1000);

        // Unauthorized maker
        CLOBTypes.Fill memory f = CLOBTypes.Fill({
            orderId: orderId,
            marketId: marketId,
            maker: user2, // not the order maker
            taker: user2,
            makerSide: CLOBTypes.Side.BUY,
            price: 6000,
            size: 1000,
            timestamp: block.timestamp
        });
        vm.prank(settler);
        vm.expectRevert(abi.encodeWithSelector(CLOBErrors.Unauthorized.selector, user2));
        settlement.settleTrade(f);

        // Market mismatch
        f.maker = user1;
        f.marketId = marketId + 1;
        vm.prank(settler);
        vm.expectRevert(); // custom error with args
        settlement.settleTrade(f);

        // Price mismatch
        f.marketId = marketId;
        f.price = 6100;
        vm.prank(settler);
        vm.expectRevert();
        settlement.settleTrade(f);
    }

    function test_SettleMultipleTrades_CoversBothSides() public {
        uint256 marketId = _createMarket(keccak256("MULTI"));
        uint256 size1 = 1_000_000; // 1 USDC (6 decimals)
        uint256 size2 = 2_000_000; // 2 USDC

        // Order 1: user1 BUY YES at 60%
        uint256 orderId1 = _placeOrder(marketId, user1, user1Pk, CLOBTypes.Side.BUY, 6000, size1);
        // Order 2: user1 SELL (maker buys NO) at 40%
        uint256 orderId2 = _placeOrder(marketId, user1, user1Pk, CLOBTypes.Side.SELL, 4000, size2);

        // Approvals for collateral transfers
        uint256 makerColl1 = (size1 * 6000) / 10000; // 0.6 USDC
        uint256 takerColl1 = size1 - makerColl1;     // 0.4 USDC
        uint256 takerColl2 = (size2 * 4000) / 10000; // for SELL, taker buys YES at price
        uint256 makerColl2 = size2 - takerColl2;

        vm.prank(user1);
        usdc.approve(address(settlement), makerColl1 + makerColl2);
        vm.prank(user2);
        usdc.approve(address(settlement), takerColl1 + takerColl2);

        CLOBTypes.Fill[] memory fills = new CLOBTypes.Fill[](2);
        fills[0] = CLOBTypes.Fill({
            orderId: orderId1,
            marketId: marketId,
            maker: user1,
            taker: user2,
            makerSide: CLOBTypes.Side.BUY,
            price: 6000,
            size: size1,
            timestamp: block.timestamp
        });
        fills[1] = CLOBTypes.Fill({
            orderId: orderId2,
            marketId: marketId,
            maker: user1,
            taker: user2,
            makerSide: CLOBTypes.Side.SELL,
            price: 4000,
            size: size2,
            timestamp: block.timestamp
        });

        vm.prank(settler);
        settlement.settleMultipleTrades(fills);

    // Token balances reflect both fills
    // user1 (maker in both): YES from first BUY, NO from second SELL
    assertEq(yesNoToken.balanceOfYes(user1, marketId), size1);
    assertEq(yesNoToken.balanceOfNo(user1, marketId), size2);
    // user2 (taker in both): NO from first trade, YES from second trade
    assertEq(yesNoToken.balanceOfNo(user2, marketId), size1);
    assertEq(yesNoToken.balanceOfYes(user2, marketId), size2);

        // Collateral tracking
        CLOBTypes.Position memory pos1 = settlement.getPosition(user1, marketId);
        CLOBTypes.Position memory pos2 = settlement.getPosition(user2, marketId);
        assertGt(pos1.collateral, 0);
        assertGt(pos2.collateral, 0);
    }

    function test_ClaimWinnings_Paths() public {
        bytes32 cond = keccak256("CLAIM");
        uint256 marketId = _createMarket(cond);
        uint256 size = 1_000_000; // 1 USDC

        // Place BUY YES order by user1
        uint256 orderId = _placeOrder(marketId, user1, user1Pk, CLOBTypes.Side.BUY, 6000, size);
        uint256 makerColl = (size * 6000) / 10000;
        uint256 takerColl = size - makerColl;

        vm.prank(user1);
        usdc.approve(address(settlement), makerColl);
        vm.prank(user2);
        usdc.approve(address(settlement), takerColl);

        CLOBTypes.Fill memory f = CLOBTypes.Fill({
            orderId: orderId,
            marketId: marketId,
            maker: user1,
            taker: user2,
            makerSide: CLOBTypes.Side.BUY,
            price: 6000,
            size: size,
            timestamp: block.timestamp
        });
        vm.prank(settler);
        settlement.settleTrade(f);

        // Claim before resolve -> revert
        vm.expectRevert(abi.encodeWithSelector(CLOBErrors.MarketNotResolved.selector, marketId));
        settlement.claimWinnings(marketId);

        // Resolve YES
        vm.warp(block.timestamp + 2 days);
        bytes memory sig = _signResolution(cond, CLOBTypes.Outcome.YES, block.timestamp, oracleSignerPk);
        CLOBTypes.ResolutionData memory resData = CLOBTypes.ResolutionData({
            marketId: marketId,
            conditionId: cond,
            outcome: CLOBTypes.Outcome.YES,
            timestamp: block.timestamp,
            oracleSignature: sig
        });
        vm.prank(admin);
        marketFactory.resolveMarket(marketId, resData);

        // Loser claims -> 0
        vm.prank(user2);
        uint256 loserPayout = settlement.claimWinnings(marketId);
        assertEq(loserPayout, 0);

        // Winner must approve fee to FeeCollector
        uint256 gross = size; // 1 USDC
        uint256 expectedFee = (gross * CLOBTypes.DEFAULT_FEE_BPS) / CLOBTypes.BPS_DIVISOR;
        vm.prank(user1);
        usdc.approve(address(feeCollector), expectedFee);
        uint256 balBefore = usdc.balanceOf(user1);
        vm.prank(user1);
        uint256 paid = settlement.claimWinnings(marketId);
        assertEq(paid, gross - expectedFee);
        assertEq(usdc.balanceOf(user1), balBefore + (gross - expectedFee) - expectedFee);

        // After claim, userCollateral zeroed
        CLOBTypes.Position memory pos1 = settlement.getPosition(user1, marketId);
        assertEq(pos1.collateral, 0);
    }

    function test_UUPS_Upgrade_Authorize() public {
        Settlement newImpl = new Settlement();
        vm.prank(admin);
        settlement.upgradeToAndCall(address(newImpl), "");
        // Check pointers unchanged
        assertEq(address(settlement.marketFactory()), address(marketFactory));
        assertEq(address(settlement.orderBook()), address(orderBook));
        assertEq(address(settlement.yesNoToken()), address(yesNoToken));
        assertEq(address(settlement.feeCollector()), address(feeCollector));
        assertEq(address(settlement.collateralToken()), address(usdc));
    }
}
