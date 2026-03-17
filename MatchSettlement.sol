// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MarketRegistry} from "./MarketRegistry.sol";

contract MatchSettlement is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable, EIP712Upgradeable, UUPSUpgradeable {
    using ECDSA for bytes32;

    bytes32 public constant BATCH_SIGNER_ROLE = keccak256("BATCH_SIGNER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    MarketRegistry public registry;

    // EIP-712 type hashes
    bytes32 private constant FILL_TYPEHASH = keccak256(
        "Fill(bytes32 marketId,address buyer,address seller,uint256 quantity,uint256 price,uint256 fee,uint256 nonce)"
    );

    bytes32 private constant BATCH_TYPEHASH = keccak256(
        "BatchSettlement(uint256 batchId,Fill[] fills,uint256 deadline)"
        "Fill(bytes32 marketId,address buyer,address seller,uint256 quantity,uint256 price,uint256 fee,uint256 nonce)"
    );

    struct Fill {
        bytes32 marketId;    // MarketRegistry market ID
        address buyer;       // Buyer address
        address seller;      // Seller address
        uint256 quantity;    // Trade size
        uint256 price;       // Price in basis points (0-9999)
        uint256 fee;         // Fee amount (accounted on backend ledger)
        uint256 nonce;       // Fill nonce for uniqueness
    }

    struct BatchSettlement {
        uint256 batchId;     // Unique batch identifier
        Fill[] fills;        // Array of fills to settle
        uint256 deadline;    // Settlement deadline timestamp
    }

    // replay guards
    mapping(uint256 => bool) public processedBatches;
    mapping(bytes32 => mapping(uint256 => bool)) public processedFills;

    event BatchSettled(
        uint256 indexed batchId,
        address indexed signer,
        uint256 fillsCount,
        uint256 totalVolume,
        uint256 totalFees
    );

    event FillSettled(
        bytes32 indexed marketId,
        address indexed buyer,
        address indexed seller,
        uint256 quantity,
        uint256 price,
        uint256 fee,
        uint256 nonce
    );

    event EmergencyPause(bool paused);

    error BatchAlreadyProcessed();
    error FillAlreadyProcessed();
    error InvalidSignature();
    error DeadlineExpired();
    error EmptyBatch();
    error InvalidFill();
    error ZeroAddress();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(address admin, address _registry) public initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __EIP712_init("PredifiMatchSettlement", "1");
        __UUPSUpgradeable_init();
        __Pausable_init();
        if (admin == address(0)) revert ZeroAddress();
        if (_registry == address(0)) revert ZeroAddress();
        registry = MarketRegistry(_registry);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(BATCH_SIGNER_ROLE,  admin);
        _grantRole(PAUSER_ROLE,        admin);
    }

    /**
     * @notice Settle a batch of matched trades
     * @param batch Batch settlement data
     * @param signature EIP-712 signature from authorized signer
     */
    function batchSettle(
        BatchSettlement calldata batch,
        bytes calldata signature
    ) external nonReentrant whenNotPaused {
        if (batch.fills.length == 0) revert EmptyBatch();
        if (block.timestamp > batch.deadline) revert DeadlineExpired();
        if (processedBatches[batch.batchId]) revert BatchAlreadyProcessed();

        bytes32 structHash = _hashBatch(batch);
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = digest.recover(signature);
        if (!hasRole(BATCH_SIGNER_ROLE, signer)) revert InvalidSignature();

        processedBatches[batch.batchId] = true;

        uint256 totalVolume = 0;
        uint256 totalFees = 0;

        for (uint256 i = 0; i < batch.fills.length; i++) {
            Fill calldata fill = batch.fills[i];
            
            // Validate and process fill
            _processFill(fill, batch.batchId);
            
            totalVolume += fill.quantity;
            totalFees += fill.fee;
        }

        emit BatchSettled(
            batch.batchId,
            signer,
            batch.fills.length,
            totalVolume,
            totalFees
        );
    }

    function _processFill(Fill calldata fill, uint256 batchId) internal {
        if (processedFills[fill.marketId][fill.nonce]) revert FillAlreadyProcessed();

        if (fill.marketId == bytes32(0) ||
            fill.buyer == address(0) || 
            fill.seller == address(0) ||
            fill.quantity == 0 ||
            fill.price >= 10000) {
            revert InvalidFill();
        }

        if (!registry.isTradable(fill.marketId)) revert InvalidFill();

        processedFills[fill.marketId][fill.nonce] = true;

        // No USDC moves. Fee was already deducted on the backend ledger.
        registry.recordTrade(
            fill.marketId,
            fill.buyer,
            fill.seller,
            fill.quantity,
            fill.price,
            fill.fee,
            batchId
        );

        emit FillSettled(
            fill.marketId,
            fill.buyer,
            fill.seller,
            fill.quantity,
            fill.price,
            fill.fee,
            fill.nonce
        );
    }

    function _hashBatch(BatchSettlement calldata batch) internal pure returns (bytes32) {
        bytes32[] memory fillHashes = new bytes32[](batch.fills.length);
        
        for (uint256 i = 0; i < batch.fills.length; i++) {
            fillHashes[i] = keccak256(abi.encode(
                FILL_TYPEHASH,
                batch.fills[i].marketId,
                batch.fills[i].buyer,
                batch.fills[i].seller,
                batch.fills[i].quantity,
                batch.fills[i].price,
                batch.fills[i].fee,
                batch.fills[i].nonce
            ));
        }

        return keccak256(abi.encode(BATCH_TYPEHASH, batch.batchId, keccak256(abi.encodePacked(fillHashes)), batch.deadline));
    }

    function getBatchHash(BatchSettlement calldata batch) external view returns (bytes32) {
        return _hashTypedDataV4(_hashBatch(batch));
    }

    function pause()     external onlyRole(PAUSER_ROLE) { _pause();   emit EmergencyPause(true);  }
    function unpause()   external onlyRole(PAUSER_ROLE) { _unpause(); emit EmergencyPause(false); }
    function setPaused(bool p) external onlyRole(PAUSER_ROLE) {
        if (p) { _pause(); emit EmergencyPause(true); } else { _unpause(); emit EmergencyPause(false); }
    }

    function isBatchProcessed(uint256 batchId) external view returns (bool) {
        return processedBatches[batchId];
    }

    function isFillProcessed(bytes32 marketId, uint256 nonce) external view returns (bool) {
        return processedFills[marketId][nonce];
    }

    function getDomainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    uint256[50] private _gap;
}