// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.22;

import "lib/evm-cctp-contracts/src/interfaces/IMintBurnToken.sol";
import "lib/evm-cctp-contracts/src/TokenMessenger.sol";
import "lib/cctp-contracts/src/TokenMessengerWithMetadata.sol";
import "lib/solmate/src/auth/Owned.sol";

/**
 * @title TokenMessengerWithMetadataWrapper
 * @notice A wrapper for a CCTP TokenMessengerWithMetatdata contract that collects fees.
 *  this contract -> TokenMessengerWithMetadata -> TokenMessenger
 *
 * depositForBurn allows users to specify any destination domain.
 * depositForBurnNoble is for minting and forwarding from Noble.
 * It allows users to supply additional IBC forwarding metadata after initiating a transfer to Noble.
 */
contract TokenMessengerWithMetadataWrapper is Owned(msg.sender) {
    // ============ Events ============
    event Collect(
        address burnToken,
        bytes32 mintRecipient,
        uint256 amountBurned, 
        uint256 fee,
        uint32 source,
        uint32 dest
    );

    event FastTransfer(
        address token,
        bytes32 mintRecipient,
        uint256 amount,
        uint32 source,
        uint32 dest
    );

    event FastTransferIBC(
        address token,
        bytes32 mintRecipient,
        uint256 amount,
        uint32 source,
        uint32 dest,
        uint64 channel,
        bytes32 destinationBech32Prefix,
        bytes32 destRecipient,
        bytes memo
    );
    
    // ============ Errors ============
    error TokenMessengerNotSet();
    error TokenMessengerWithMetadataNotSet();
    error TokenNotSupported();
    error FeeNotFound();
    error BurnAmountTooLow();
    error NotFeeUpdater();
    error PercFeeTooHigh();
    
    // ============ State Variables ============
    // Circle contract for burning tokens
    TokenMessenger public immutable tokenMessenger;
    // Noble contract for including IBC forwarding metadata
    TokenMessengerWithMetadata public tokenMessengerWithMetadata;
    // the domain id this contract is deployed on
    uint32 public immutable currentDomainId;
    // noble domain id (4)
    uint32 public immutable nobleDomainId = 4;
    // address that can collect fees
    address public collector;
    // address that can update fees
    address public feeUpdater;

    // fast transfer - allowed erc20 tokens
    mapping(address => bool) public allowedTokens;

    struct Fee {
        // percentage fee in bips
        uint16 percFee;
        // flat fee in uusdc (1 uusdc = 10^-6 usdc)
        uint64 flatFee;
        // needed for null check
        bool isInitialized;
    }

    // destination domain id -> fee
    mapping(uint32 => Fee) public feeMap;

    // ============ Constructor ============
    /**
     * @param _tokenMessenger TokenMessenger address
     * @param _tokenMessengerWithMetadata TokenMessengerWithMetadata address
     * @param _currentDomainId the domain id this contract is deployed on
     * @param _collector address that can collect fees
     * @param _feeUpdater address that can update fees
     */
    constructor(
        address _tokenMessenger,
        address _tokenMessengerWithMetadata,
        uint32 _currentDomainId,
        address _collector,
        address _feeUpdater
    ) {
        if (_tokenMessenger == address(0)) {
            revert TokenMessengerNotSet();
        }
        tokenMessenger = TokenMessenger(_tokenMessenger);

        if(_tokenMessengerWithMetadata == address(0)) {
            revert TokenMessengerWithMetadataNotSet();
        }
        tokenMessengerWithMetadata = TokenMessengerWithMetadata(_tokenMessengerWithMetadata);

        currentDomainId = _currentDomainId;
        collector = _collector;
        feeUpdater = _feeUpdater;
    }

    // ============ External Functions ============
    /**
     * @notice Wrapper function for TokenMessenger.depositForBurn() and .depositForBurnWithCaller()
     * If destinationCaller is empty, call "depositForBurnWithCaller", otherwise call "depositForBurn".
     * Can specify any destination domain.
     *
     * @param amount - the burn amount
     * @param destinationDomain - domain id the funds will be minted on
     * @param mintRecipient - address receiving minted tokens on destination domain
     * @param burnToken - address of the token being burned on the source chain
     * @param destinationCaller - address allowed to mint on destination chain
     */
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller
    ) external {
        // collect fee
        uint256 fee;
        uint256 remainder;
        (fee, remainder) = calculateFee(amount, destinationDomain);

        IMintBurnToken token = IMintBurnToken(burnToken);
        token.transferFrom(msg.sender, address(this), amount);

        if (destinationCaller == bytes32(0)) {
            tokenMessenger.depositForBurn(
                remainder,
                destinationDomain,
                mintRecipient,
                burnToken
            );
        } else {
            tokenMessenger.depositForBurnWithCaller(
                remainder,
                destinationDomain,
                mintRecipient,
                burnToken,
                destinationCaller
            );
        }
        emit Collect(burnToken, mintRecipient, remainder, fee, currentDomainId, destinationDomain);
    }

    /**
     * @notice Wrapper function for "depositForBurn" that includes metadata.
     * Only for minting to Noble (destination domain is hardcoded).
     *
     * @param channel channel id to be used when ibc forwarding
     * @param destinationBech32Prefix bech32 prefix used for address encoding once ibc forwarded
     * @param destinationRecipient address of recipient once ibc forwarded
     * @param amount amount of tokens to burn
     * @param mintRecipient address of mint recipient on destination domain
     * @param burnToken address of contract to burn deposited tokens, on local domain
     * @param memo arbitrary memo to be included when ibc forwarding
     */
    function depositForBurnNoble(
        uint64 channel,
        bytes32 destinationBech32Prefix,
        bytes32 destinationRecipient,
        uint256 amount,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        bytes calldata memo
    ) external {
        // collect fee
        uint256 fee;
        uint256 remainder;
        (fee, remainder) = calculateFee(amount, nobleDomainId);

        IMintBurnToken token = IMintBurnToken(burnToken);
        token.transferFrom(msg.sender, address(this), amount);

        if (destinationCaller == bytes32(0)) {
            tokenMessengerWithMetadata.depositForBurn(
                channel,
                destinationBech32Prefix,
                destinationRecipient,
                remainder,
                mintRecipient,
                burnToken,
                memo
            );
        } else {
            tokenMessengerWithMetadata.depositForBurnWithCaller(
                channel,
                destinationBech32Prefix,
                destinationRecipient,
                remainder,
                mintRecipient,
                burnToken,
                destinationCaller,
                memo
            );
        }

        emit Collect(burnToken, mintRecipient, remainder, fee, currentDomainId, nobleDomainId);
    }

    /**
     * @notice For fast, custodial transfers.  Fees are collected on the backend.
     *
     * @param amount amount of tokens to burn
     * @param destinationDomain domain id the funds will be received on
     * @param recipient address of mint recipient on destination domain
     * @param token address of contract to burn deposited tokens, on local domain
     */
    function fastTransfer(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 recipient,
        address token
    ) external {
        // only allow certain tokens for this domain
        if (allowedTokens[token] != true) {
            revert TokenNotSupported();
        }

        IMintBurnToken mintBurntoken = IMintBurnToken(token);
        mintBurntoken.transferFrom(msg.sender, address(this), amount);

        // emit event
        emit FastTransfer(
            token,
            recipient,
            amount,
            currentDomainId,
            destinationDomain
        );
    }

    /**
     * @notice For fast, custodial transfers require a second IBC forward.  Fees are collected on the backend.
     * Only for minting to Noble (destination domain is hardcoded)
     *
     * @param amount amount of tokens to burn
     * @param recipient address of fallback mint recipient on Noble
     * @param token address of contract to burn deposited tokens, on local domain
     * @param channel channel id to be used when ibc forwarding
     * @param destinationBech32Prefix bech32 prefix used for address encoding once ibc forwarded
     * @param destinationRecipient address of recipient once ibc forwarded
     * @param memo arbitrary memo to be included when ibc forwarding
     */
    function fastTransferIBC(
        uint256 amount,
        bytes32 recipient,
        address token,
        uint64 channel,
        bytes32 destinationBech32Prefix,
        bytes32 destinationRecipient,
        bytes calldata memo
    ) external {
        // only allow certain tokens for this domain
        if (allowedTokens[token] != true) {
            revert TokenNotSupported();
        }
        IMintBurnToken mintBurntoken = IMintBurnToken(token);
        mintBurntoken.transferFrom(msg.sender, address(this), amount);

        // emit event
        emit FastTransferIBC(
            token,
            recipient,
            amount,
            currentDomainId,
            nobleDomainId,
            channel,
            destinationBech32Prefix,
            destinationRecipient,
            memo
        );
    }

    function updateTokenMessengerWithMetadata(address newTokenMessenger) external onlyOwner {
        tokenMessengerWithMetadata = TokenMessengerWithMetadata(newTokenMessenger);
    }

    function calculateFee(uint256 amount, uint32 destinationDomain) private view onlyOwner returns (uint256, uint256) {
        Fee memory entry = feeMap[destinationDomain];
        if (!entry.isInitialized) {
            revert FeeNotFound();
        }

        uint256 fee = (amount * entry.percFee) / 10000 + entry.flatFee;
        if (amount <= fee) {
            revert BurnAmountTooLow();
        }
        // fee, remainder
        return (fee, amount-fee);
    }

    function setFee(uint32 destinationDomain, uint16 percFee, uint64 flatFee) external {
        if (msg.sender != feeUpdater) {
            revert NotFeeUpdater();
        }
        if (percFee > 100) { // 1%
            revert PercFeeTooHigh();
        }
        feeMap[destinationDomain] = Fee(percFee, flatFee, true);
    }

    function updateOwner(address newOwner) external onlyOwner {
        owner = newOwner;
    }

    function updateCollector(address newCollector) external onlyOwner {
        collector = newCollector;
    }

    function updateFeeUpdater(address newFeeUpdater) external onlyOwner {
        feeUpdater = newFeeUpdater;
    }

    function allowAddress(address newAllowedAddress) external onlyOwner {
        allowedTokens[newAllowedAddress] = true;
        IERC20 token = IERC20(newAllowedAddress);
        token.approve(address(tokenMessenger), type(uint256).max);
        token.approve(address(tokenMessengerWithMetadata), type(uint256).max);
    }

    function disallowAddress(address newDisallowedAddress) external onlyOwner {
        allowedTokens[newDisallowedAddress] = false;
        IERC20 token = IERC20(newDisallowedAddress);
        token.approve(address(tokenMessenger), 0);
        token.approve(address(tokenMessengerWithMetadata), 0);
    }

    function withdrawFees(address tokenAddress) external onlyOwner {
        uint256 balance = IERC20(tokenAddress).balanceOf(address(this));
        IERC20 token = IERC20(tokenAddress);
        token.transfer(collector, balance);
    }
}
