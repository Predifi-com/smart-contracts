// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../libs/CLOBTypes.sol";
import "../libs/CLOBErrors.sol";
import "../interfaces/ICLOBCore.sol";

/**
 * @title YesNoToken
 * @notice Upgradeable ERC1155 tokens representing YES/NO positions in prediction markets
 * @dev Token IDs encode: marketId * 2 (YES) or marketId * 2 + 1 (NO)
 * @custom:security-contact security@predifi.com
 */
contract YesNoToken is 
    ERC1155Upgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    IYesNoToken
{
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract
     * @param admin Address to receive admin roles
     * @param uri_ Base URI for token metadata
     */
    function initialize(address admin, string memory uri_) public initializer {
        if (admin == address(0)) revert CLOBErrors.ZeroAddress();

        __ERC1155_init(uri_);
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
    }

    /**
     * @notice Mint YES or NO tokens for a market
     * @param to Recipient address
     * @param marketId Market identifier
     * @param isYes True for YES tokens, false for NO tokens
     * @param amount Amount to mint
     */
    function mint(
        address to,
        uint256 marketId,
        bool isYes,
        uint256 amount
    ) external onlyRole(MINTER_ROLE) {
        if (to == address(0)) revert CLOBErrors.ZeroAddress();
        if (amount == 0) revert CLOBErrors.ZeroAmount();

        uint256 tokenId = getTokenId(marketId, isYes);
        _mint(to, tokenId, amount, "");
    }

    /**
     * @notice Burn YES or NO tokens
     * @param from Address to burn from
     * @param marketId Market identifier
     * @param isYes True for YES tokens, false for NO tokens
     * @param amount Amount to burn
     */
    function burn(
        address from,
        uint256 marketId,
        bool isYes,
        uint256 amount
    ) external onlyRole(MINTER_ROLE) {
        if (from == address(0)) revert CLOBErrors.ZeroAddress();
        if (amount == 0) revert CLOBErrors.ZeroAmount();

        uint256 tokenId = getTokenId(marketId, isYes);
        uint256 balance = balanceOf(from, tokenId);
        if (balance < amount) {
            revert CLOBErrors.InsufficientBalance(amount, balance);
        }

        _burn(from, tokenId, amount);
    }

    /**
     * @notice Get token ID for a market and outcome
     * @param marketId Market identifier
     * @param isYes True for YES, false for NO
     * @return tokenId The computed token ID
     */
    function getTokenId(uint256 marketId, bool isYes) public pure returns (uint256) {
        return isYes 
            ? (marketId * 2 + CLOBTypes.YES_TOKEN_ID_OFFSET)
            : (marketId * 2 + CLOBTypes.NO_TOKEN_ID_OFFSET);
    }

    /**
     * @notice Get YES token balance for an account
     * @param account User address
     * @param marketId Market identifier
     * @return Balance of YES tokens
     */
    function balanceOfYes(address account, uint256 marketId) external view returns (uint256) {
        return balanceOf(account, getTokenId(marketId, true));
    }

    /**
     * @notice Get NO token balance for an account
     * @param account User address
     * @param marketId Market identifier
     * @return Balance of NO tokens
     */
    function balanceOfNo(address account, uint256 marketId) external view returns (uint256) {
        return balanceOf(account, getTokenId(marketId, false));
    }

    /**
     * @notice Update the base URI
     * @param newuri New base URI
     */
    function setURI(string memory newuri) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setURI(newuri);
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

    /**
     * @inheritdoc ERC1155Upgradeable
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
