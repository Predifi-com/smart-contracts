// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { IERC1155Receiver } from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";

import { ReceiptRouter, ISettlementMessenger } from "contracts/venue/ReceiptRouter.sol";

contract MockERC1155 is IERC1155 {
    mapping(uint256 => mapping(address => uint256)) public balances;

    function uri(uint256) external pure returns (string memory) { return ""; }

    function balanceOf(address account, uint256 id) external view override returns (uint256) {
        return balances[id][account];
    }

    function balanceOfBatch(address[] calldata, uint256[] calldata) external pure override returns (uint256[] memory) {
        revert("not-implemented");
    }

    function setApprovalForAll(address, bool) external pure override {}
    function isApprovedForAll(address, address) external pure override returns (bool) { return true; }

    function safeTransferFrom(address from, address to, uint256 id, uint256 value, bytes calldata data) external override {
        // Deduct from sender
    require(balances[id][from] >= value, "insufficient");
    balances[id][from] -= value;
        // Credit to receiver
    balances[id][to] += value;
        // Call receiver hook
        if (to.code.length > 0) {
            bytes4 retval = IERC1155Receiver(to).onERC1155Received(msg.sender, from, id, value, data);
            require(retval == IERC1155Receiver.onERC1155Received.selector, "!ERC1155Recv");
        }
    }

    function safeBatchTransferFrom(address from, address to, uint256[] calldata ids, uint256[] calldata values, bytes calldata data) external override {
        for (uint i = 0; i < ids.length; i++) {
            require(balances[ids[i]][from] >= values[i], "insufficient");
            balances[ids[i]][from] -= values[i];
            balances[ids[i]][to] += values[i];
        }
        if (to.code.length > 0) {
            bytes4 retval = IERC1155Receiver(to).onERC1155BatchReceived(msg.sender, from, ids, values, data);
            require(retval == IERC1155Receiver.onERC1155BatchReceived.selector, "!ERC1155BatchRecv");
        }
    }

    function mint(address to, uint256 id, uint256 value) external {
        balances[id][to] += value;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        // IERC165 (0x01ffc9a7) or IERC1155 (0xd9b67a26)
        return interfaceId == 0x01ffc9a7 || interfaceId == 0xd9b67a26;
    }
}

contract MockMessenger is ISettlementMessenger {
    bytes32 public lastOrderId;
    uint256 public lastAmountDelta;
    uint64 public lastEscrowChainId;
    address public lastAuthority;
    uint256 public callCount;

    function attestFill(bytes32 orderId, uint256 amountDelta, uint64 escrowChainId, address authority) external override {
        lastOrderId = orderId;
        lastAmountDelta = amountDelta;
        lastEscrowChainId = escrowChainId;
        lastAuthority = authority;
        callCount++;
    }
}

contract ReceiptRouterTest is Test {
    ReceiptRouter impl;
    ReceiptRouter router;
    MockERC1155 token;
    MockMessenger messenger;

    address admin = address(0xA11CE);
    address operator = address(0xB0B);
    address userAA = address(0xAA);
    address settlement = address(0x5E771E);

    function setUp() public {
        token = new MockERC1155();
        messenger = new MockMessenger();

        impl = new ReceiptRouter();
        bytes memory initData = abi.encodeWithSelector(ReceiptRouter.initialize.selector, admin);
        router = ReceiptRouter(address(new ERC1967Proxy(address(impl), initData)));

        // Roles and config
        vm.startPrank(admin);
        router.grantRole(router.OPERATOR_ROLE(), operator);
        router.setAllowedSender(settlement, true);
        router.setMessenger(address(messenger));
        vm.stopPrank();
    }

    function _register(bytes32 orderId, uint256 tokenId, bool forward) internal {
        vm.prank(operator);
        router.registerExpected(orderId, userAA, address(token), tokenId, 0, forward, 1234, address(0xC10));
    }

    function test_receive_forwards_to_user_and_attests() public {
        bytes32 orderId = keccak256("ORDER-A");
        uint256 tokenId = 1;
        _register(orderId, tokenId, true);

        // Mint tokens to settlement executor and send to router
        token.mint(settlement, tokenId, 100);
        vm.prank(settlement);
        token.safeTransferFrom(settlement, address(router), tokenId, 60, abi.encode(orderId));

        // Forwarded to user
        assertEq(token.balanceOf(userAA, tokenId), 60);
        // Attestation called
        assertEq(messenger.callCount(), 1);
        assertEq(messenger.lastOrderId(), orderId);
        assertEq(messenger.lastAmountDelta(), 60);
    }

    function test_receive_holds_when_forward_false() public {
        bytes32 orderId = keccak256("ORDER-B");
        uint256 tokenId = 2;
        _register(orderId, tokenId, false);

        token.mint(settlement, tokenId, 50);
        vm.prank(settlement);
        token.safeTransferFrom(settlement, address(router), tokenId, 50, abi.encode(orderId));

        // Held in router
        assertEq(token.balanceOf(address(router), tokenId), 50);
        // No forwarding to user
        assertEq(token.balanceOf(userAA, tokenId), 0);
    }

    function test_rejects_unallowed_sender_or_bad_data() public {
        bytes32 orderId = keccak256("ORDER-C");
        _register(orderId, 3, true);
        token.mint(address(0xBAD), 3, 10);
        // Unallowed operator
        vm.expectRevert(bytes("SenderNotAllowed"));
        vm.prank(address(0xBAD));
        token.safeTransferFrom(address(0xBAD), address(router), 3, 10, abi.encode(orderId));

        // Allowed but missing orderId in data
        token.mint(settlement, 3, 10);
        vm.expectRevert(bytes("OrderIdRequired"));
        vm.prank(settlement);
        token.safeTransferFrom(settlement, address(router), 3, 10, "");
    }

    function test_batch_receive_forwards_and_attests_total() public {
        bytes32 orderId = keccak256("ORDER-D");
        uint256 tokenId = 4;
        _register(orderId, tokenId, true);

        uint256[] memory ids = new uint256[](3);
        uint256[] memory amounts = new uint256[](3);
        ids[0] = tokenId; ids[1] = tokenId; ids[2] = tokenId;
        amounts[0] = 10; amounts[1] = 15; amounts[2] = 5;

        token.mint(settlement, tokenId, 100);
        vm.prank(settlement);
        token.safeBatchTransferFrom(settlement, address(router), ids, amounts, abi.encode(orderId));

        // Forwarded total to user
        assertEq(token.balanceOf(userAA, tokenId), 30);
        // Single attestation with total amount
        assertEq(messenger.callCount(), 1);
        assertEq(messenger.lastOrderId(), orderId);
        assertEq(messenger.lastAmountDelta(), 30);
    }

    function test_batch_receive_tokenId_mismatch_reverts() public {
        bytes32 orderId = keccak256("ORDER-E");
        uint256 tokenId = 5;
        _register(orderId, tokenId, false);

        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        ids[0] = tokenId; ids[1] = tokenId + 1; // mismatch on second item
        amounts[0] = 7; amounts[1] = 3;

        // Mint sufficient balances for both token IDs so transfer reaches router hook
        token.mint(settlement, tokenId, 10);
        token.mint(settlement, tokenId + 1, 10);
        vm.expectRevert(bytes("TokenIdMismatch"));
        vm.prank(settlement);
        token.safeBatchTransferFrom(settlement, address(router), ids, amounts, abi.encode(orderId));
    }

    function test_attest_skipped_when_messenger_unset() public {
        // Fresh router without messenger
        ReceiptRouter freshImpl = new ReceiptRouter();
        bytes memory initData2 = abi.encodeWithSelector(ReceiptRouter.initialize.selector, admin);
        ReceiptRouter fresh = ReceiptRouter(address(new ERC1967Proxy(address(freshImpl), initData2)));

        // Configure roles and allowlist
        vm.startPrank(admin);
        fresh.grantRole(fresh.OPERATOR_ROLE(), operator);
        fresh.setAllowedSender(settlement, true);
        vm.stopPrank();

        // Register expected receipt
        vm.prank(operator);
        fresh.registerExpected(keccak256("ORDER-F"), userAA, address(token), 6, 0, true, 1234, address(0xC10));

        token.mint(settlement, 6, 10);
        vm.prank(settlement);
        token.safeTransferFrom(settlement, address(fresh), 6, 10, abi.encode(keccak256("ORDER-F")));

        // Attestation should be skipped (no messenger configured)
        assertEq(messenger.callCount(), 0);
        // Tokens forwarded to user
        assertEq(token.balanceOf(userAA, 6), 10);
    }
}
