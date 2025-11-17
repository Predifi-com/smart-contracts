// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { IERC1155Receiver } from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";

import { ReceiptRouter, ISettlementMessenger } from "contracts/venue/ReceiptRouter.sol";

contract MockERC1155F is IERC1155 {
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
        require(balances[id][from] >= value, "insufficient");
        balances[id][from] -= value;
        balances[id][to] += value;
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
        return interfaceId == 0x01ffc9a7 || interfaceId == 0xd9b67a26;
    }
}

contract MockMessengerF is ISettlementMessenger {
    uint256 public totalDelta;
    function attestFill(bytes32, uint256 amountDelta, uint64, address) external override {
        totalDelta += amountDelta;
    }
}

contract ReceiptRouterFuzzTest is Test {
    ReceiptRouter router;
    MockERC1155F token;
    MockMessengerF messenger;

    address admin = address(0xA11CE);
    address operator = address(0xB0B);
    address settlement = address(0x5E771E);
    address userAA = address(0xAA);

    function setUp() public {
        token = new MockERC1155F();
        messenger = new MockMessengerF();

        ReceiptRouter impl = new ReceiptRouter();
        bytes memory initData = abi.encodeWithSelector(ReceiptRouter.initialize.selector, admin);
        router = ReceiptRouter(address(new ERC1967Proxy(address(impl), initData)));

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

    // Fuzz forward path, ensure cumulative attestation equals total received and never overflows uint256
    function testFuzz_forward_cumulative(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 0, 1e18);
        b = bound(b, 0, 1e18);
        c = bound(c, 0, 1e18);
        bytes32 orderId = keccak256("ORDER-FUZZ-1");
        uint256 tokenId = 77;
        _register(orderId, tokenId, true);

        token.mint(settlement, tokenId, a + b + c);

        if (a > 0) { vm.prank(settlement); token.safeTransferFrom(settlement, address(router), tokenId, a, abi.encode(orderId)); }
        if (b > 0) { vm.prank(settlement); token.safeTransferFrom(settlement, address(router), tokenId, b, abi.encode(orderId)); }
        if (c > 0) { vm.prank(settlement); token.safeTransferFrom(settlement, address(router), tokenId, c, abi.encode(orderId)); }

        assertEq(messenger.totalDelta(), a + b + c);
        assertEq(token.balanceOf(userAA, tokenId), a + b + c);
    }

    // Fuzz hold path, ensure cumulative accounting on router storage and attest totals match
    function testFuzz_hold_cumulative(uint256 a, uint256 b) public {
        a = bound(a, 0, 1e18);
        b = bound(b, 0, 1e18);
        bytes32 orderId = keccak256("ORDER-FUZZ-2");
        uint256 tokenId = 88;
        _register(orderId, tokenId, false);

        token.mint(settlement, tokenId, a + b);
        if (a > 0) { vm.prank(settlement); token.safeTransferFrom(settlement, address(router), tokenId, a, abi.encode(orderId)); }
        if (b > 0) { vm.prank(settlement); token.safeTransferFrom(settlement, address(router), tokenId, b, abi.encode(orderId)); }

        assertEq(messenger.totalDelta(), a + b);
        // Held on router
        assertEq(token.balanceOf(address(router), tokenId), a + b);
    }
}
