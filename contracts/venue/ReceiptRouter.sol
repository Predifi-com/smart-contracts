// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/utils/ERC1155HolderUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

interface ISettlementMessenger {
    function attestFill(bytes32 orderId, uint256 amountDelta, uint64 escrowChainId, address authority) external;
}

/**
 * @title ReceiptRouter
 * @notice Venue-chain receiver for ERC1155 YES/NO tokens. Optionally forwards to user AA and
 *         emits cross-chain attestation to SettlementAuthority on the escrow chain.
 */
contract ReceiptRouter is UUPSUpgradeable, AccessControlUpgradeable, PausableUpgradeable, ERC1155HolderUpgradeable {
    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE");

    struct ExpectedReceipt {
        address userAA;
        address token;
        uint256 tokenId;
        uint256 minAmount;
        bool forward;
        uint64 escrowChainId;
        address settlementAuthority;
        uint256 cumulative;
        bool active;
    }

    // orderId => expectation
    mapping(bytes32 => ExpectedReceipt) public expected;

    // Allowlist of venue-side settlement executors (checked via `operator` param)
    mapping(address => bool) public allowedSenders;

    // Optional messenger for cross-chain attestation (Via Labs or similar)
    address public settlementMessenger;

    event ExpectedRegistered(bytes32 indexed orderId, address indexed userAA, address indexed token, uint256 tokenId, uint256 minAmount, bool forward, uint64 escrowChainId, address settlementAuthority);
    event AllowedSenderSet(address indexed sender, bool allowed);
    event MessengerSet(address indexed messenger);
    event ReceivedAndForwarded(bytes32 indexed orderId, address indexed token, uint256 indexed tokenId, uint256 amount, address to);
    event ReceivedAndHeld(bytes32 indexed orderId, address indexed token, uint256 indexed tokenId, uint256 amount);
    event AttestationSent(bytes32 indexed orderId, uint256 amountDelta, uint64 escrowChainId, address settlementAuthority);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(address admin) external initializer {
        require(admin != address(0), "ZeroAdmin");
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();

        _grantRole(ADMIN_ROLE, admin);
        _grantRole(PAUSE_ROLE, admin);
    }

    function setAllowedSender(address sender, bool allowed) external onlyRole(ADMIN_ROLE) {
        require(sender != address(0), "ZeroAddr");
        allowedSenders[sender] = allowed;
        emit AllowedSenderSet(sender, allowed);
    }

    function setMessenger(address messenger) external onlyRole(ADMIN_ROLE) {
        require(messenger != address(0), "ZeroAddr");
        settlementMessenger = messenger;
        emit MessengerSet(messenger);
    }

    function registerExpected(
        bytes32 orderId,
        address userAA,
        address token,
        uint256 tokenId,
        uint256 minAmount,
        bool forward,
        uint64 escrowChainId,
        address settlementAuthority
    ) external onlyRole(OPERATOR_ROLE) whenNotPaused {
        require(orderId != bytes32(0), "BadOrderId");
        require(!expected[orderId].active, "Exists");
        require(userAA != address(0) && token != address(0) && settlementAuthority != address(0), "ZeroAddr");

        expected[orderId] = ExpectedReceipt({
            userAA: userAA,
            token: token,
            tokenId: tokenId,
            minAmount: minAmount,
            forward: forward,
            escrowChainId: escrowChainId,
            settlementAuthority: settlementAuthority,
            cumulative: 0,
            active: true
        });

        emit ExpectedRegistered(orderId, userAA, token, tokenId, minAmount, forward, escrowChainId, settlementAuthority);
    }

    function onERC1155Received(
        address operator,
        address /* from */,
        uint256 id,
        uint256 value,
        bytes memory data
    ) public override whenNotPaused returns (bytes4) {
        require(allowedSenders[operator], "SenderNotAllowed");
        require(data.length == 32, "OrderIdRequired");
        bytes32 orderId = abi.decode(data, (bytes32));
        ExpectedReceipt storage ex = expected[orderId];
        require(ex.active, "NoExpectation");
        require(msg.sender == ex.token && id == ex.tokenId, "TokenMismatch");

        ex.cumulative += value;

        if (ex.forward) {
            IERC1155(msg.sender).safeTransferFrom(address(this), ex.userAA, id, value, "");
            emit ReceivedAndForwarded(orderId, msg.sender, id, value, ex.userAA);
        } else {
            emit ReceivedAndHeld(orderId, msg.sender, id, value);
        }

        _attest(orderId, value, ex.escrowChainId, ex.settlementAuthority);
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address operator,
        address /* from */,
        uint256[] memory ids,
        uint256[] memory values,
        bytes memory data
    ) public override whenNotPaused returns (bytes4) {
        require(allowedSenders[operator], "SenderNotAllowed");
        require(data.length == 32, "OrderIdRequired");
        bytes32 orderId = abi.decode(data, (bytes32));
        ExpectedReceipt storage ex = expected[orderId];
        require(ex.active, "NoExpectation");
        require(msg.sender == ex.token, "TokenMismatch");

        uint256 len = ids.length;
        require(len == values.length, "LengthMismatch");
        for (uint256 i = 0; i < len; i++) {
            require(ids[i] == ex.tokenId, "TokenIdMismatch");
            ex.cumulative += values[i];
            if (ex.forward) {
                IERC1155(msg.sender).safeTransferFrom(address(this), ex.userAA, ids[i], values[i], "");
                emit ReceivedAndForwarded(orderId, msg.sender, ids[i], values[i], ex.userAA);
            } else {
                emit ReceivedAndHeld(orderId, msg.sender, ids[i], values[i]);
            }
        }

        uint256 total;
        for (uint256 i = 0; i < len; i++) total += values[i];
        _attest(orderId, total, ex.escrowChainId, ex.settlementAuthority);
        return this.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) public view override(AccessControlUpgradeable, ERC1155HolderUpgradeable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function pause() external onlyRole(PAUSE_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSE_ROLE) { _unpause(); }

    function _attest(bytes32 orderId, uint256 amountDelta, uint64 escrowChainId, address authority) internal {
        if (settlementMessenger != address(0)) {
            ISettlementMessenger(settlementMessenger).attestFill(orderId, amountDelta, escrowChainId, authority);
            emit AttestationSent(orderId, amountDelta, escrowChainId, authority);
        }
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}
}
