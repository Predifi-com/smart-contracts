// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "../libs/CLOBTypes.sol";
import "../libs/CLOBErrors.sol";
import "../interfaces/ICLOBCore.sol";

/**
 * @title OracleAdapter
 * @notice Adapter for Stork Network oracle integration
 * @dev Verifies oracle signatures for market resolution
 * @custom:security-contact security@predifi.com
 */
contract OracleAdapter is 
    AccessControlUpgradeable,
    UUPSUpgradeable,
    IOracleAdapter
{
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    bytes32 public constant ORACLE_MANAGER_ROLE = keccak256("ORACLE_MANAGER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice Stork oracle signer address
    address public storkOracle;

    /// @notice Maximum allowed age for oracle data (seconds)
    uint256 public maxDataAge;

    /// @notice EIP-712 domain separator
    bytes32 private _domainSeparator;

    /// @notice EIP-712 type hash for resolution data
    bytes32 public constant RESOLUTION_TYPEHASH = keccak256(
        "Resolution(bytes32 conditionId,uint8 outcome,uint256 timestamp)"
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract
     * @param admin Address to receive admin roles
     * @param oracle_ Stork oracle signer address
     * @param maxDataAge_ Maximum data age in seconds
     */
    function initialize(
        address admin,
        address oracle_,
        uint256 maxDataAge_
    ) public initializer {
        if (admin == address(0) || oracle_ == address(0)) {
            revert CLOBErrors.ZeroAddress();
        }

        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(ORACLE_MANAGER_ROLE, admin);

        storkOracle = oracle_;
        maxDataAge = maxDataAge_;

        _domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("PredifiOracle"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    /**
     * @notice Verify oracle resolution signature
     * @param conditionId Stork condition identifier
     * @param outcome Market outcome
     * @param timestamp Resolution timestamp
     * @param signature Oracle signature
     * @return valid True if signature is valid
     */
    function verifyResolution(
        bytes32 conditionId,
        CLOBTypes.Outcome outcome,
        uint256 timestamp,
        bytes calldata signature
    ) external view returns (bool) {
        // Check data freshness
        if (block.timestamp > timestamp + maxDataAge) {
            revert CLOBErrors.OracleDataStale(timestamp);
        }

        // Construct EIP-712 hash
        bytes32 structHash = keccak256(
            abi.encode(
                RESOLUTION_TYPEHASH,
                conditionId,
                uint8(outcome),
                timestamp
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", _domainSeparator, structHash)
        );

        // Recover signer
        address signer = digest.recover(signature);
        
        return signer == storkOracle;
    }

    /**
     * @notice Update Stork oracle address
     * @param newOracle New oracle signer address
     */
    function updateOracle(address newOracle) external onlyRole(ORACLE_MANAGER_ROLE) {
        if (newOracle == address(0)) revert CLOBErrors.ZeroAddress();
        storkOracle = newOracle;
        emit OracleUpdated(newOracle);
    }

    /**
     * @notice Update maximum data age
     * @param newMaxAge New maximum age in seconds
     */
    function updateMaxDataAge(uint256 newMaxAge) external onlyRole(ORACLE_MANAGER_ROLE) {
        maxDataAge = newMaxAge;
    }

    /**
     * @notice Get current oracle address
     * @return Oracle signer address
     */
    function getStorkOracle() external view returns (address) {
        return storkOracle;
    }

    /**
     * @notice Get domain separator
     * @return EIP-712 domain separator
     */
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparator;
    }

    /**
     * @notice Authorize upgrades (UUPS pattern)
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(address newImplementation) 
        internal 
        override 
        onlyRole(UPGRADER_ROLE) 
    {
        // Authorization check via modifier
    }
}
