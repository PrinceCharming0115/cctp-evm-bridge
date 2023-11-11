// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.7.6;

import "lib/evm-cctp-contracts/src/interfaces/IMintBurnToken.sol";
import "lib/evm-cctp-contracts/src/TokenMessenger.sol";
import "lib/cctp-contracts/src/TokenMessengerWithMetadata.sol";

/**
 * @title TokenMessengerWithMetadataWrapper
 * @notice A wrapper for a CCTP TokenMessengerWithMetatdata contract that collects fees.
 *  this contract -> TokenMessengerWithMetadata -> TokenMessenger 
 *
 * depositForBurn allows users to specify any destination domain.
 * depositForBurnNoble is for minting and forwarding from Noble.  
 *  It allows users to supply additional IBC forwarding metadata after initiating a transfer to Noble.
 */
contract TokenMessengerWithMetadataWrapper {
    // ============ Events ============
    event Collect(
        address indexed burnToken, 
        bytes32 mintRecipient, 
        uint256 indexed amountBurned, 
        uint256 indexed fee,
        uint32 source, 
        uint32 dest
    );

    event FastTransfer(
        address token,
        bytes32 indexed mintRecipient,
        uint256 amount,
        uint32 indexed source,
        uint32 indexed dest
    );

    event FastTransferIBC(
        address token,
        bytes32 indexed mintRecipient,
        uint256 amount,
        uint32 indexed source,
        uint32 indexed dest,
        uint64 channel,
        bytes32 destinationBech32Prefix,
        bytes32 destRecipient,
        bytes memo
    );

    // ============ State Variables ============
    TokenMessenger public tokenMessenger;
    TokenMessengerWithMetadata public tokenMessengerWithMetadata;

    // the domain id this contract is deployed on
    uint32 public immutable currentDomainId;
    // address which sets fees and collector
    address public owner;
    // address which fees are sent to
    address payable public collector; 
    // address which can update fees
    address public feeUpdater;
    // current contract address (gas optimiation)
    address public immutable contractAddress;

    // fast transfer - allowed erc20 tokens
    mapping(address => bool) public allowedTokens;    

    struct Fee {
        // percentage fee in bips
        uint256 percFee;
        // flat fee in uusdc (1 uusdc = 10^-6 usdc)
        uint256 flatFee;
        // needed for null check
        bool isInitialized;
    }
    
    // destination domain id -> fee
    mapping(uint32 => Fee) public feeMap;

    // ============ Constructor ============
    /**
     * @param _tokenMessenger TokenMessenger address
     * @param _tokenMessengerWithMetadata TokenMessengerWithMetadata address
     * @param _currentDomainId The domain id this contract is deployed on
     * @param _collector address which fees are sent to
     */
    constructor(
        address _tokenMessenger,
        address _tokenMessengerWithMetadata,
        uint32 _currentDomainId,
        address payable _collector,
        address _feeUpdater
    ) {
        require(_tokenMessenger != address(0), "TokenMessenger not set");
        tokenMessenger = TokenMessenger(_tokenMessenger);

        require(_tokenMessengerWithMetadata != address(0), "TMWithMetadata not set");
        tokenMessengerWithMetadata = TokenMessengerWithMetadata(_tokenMessengerWithMetadata);

        contractAddress = address(this);

        currentDomainId = _currentDomainId;
        collector = _collector;
        feeUpdater = _feeUpdater;
        owner = msg.sender;
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
        uint256 fee = calculateFee(amount, destinationDomain);
        IMintBurnToken token = IMintBurnToken(burnToken);
        token.transferFrom(msg.sender, contractAddress, amount);
        token.transfer(collector, fee);
        token.approve(address(tokenMessenger), amount-fee);

        if (destinationCaller == bytes32(0)) {
            tokenMessenger.depositForBurn(
                amount - fee, 
                destinationDomain, 
                mintRecipient, 
                burnToken
            );
        } else {
            tokenMessenger.depositForBurnWithCaller(
                amount - fee, 
                destinationDomain, 
                mintRecipient, 
                burnToken,
                destinationCaller
            );
        }
        emit Collect(burnToken, mintRecipient, amount-fee, fee, currentDomainId, destinationDomain);
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
        uint256 fee = calculateFee(amount, uint32(4)); // noble domain id is 4
        IMintBurnToken token = IMintBurnToken(burnToken);
        token.transferFrom(msg.sender, contractAddress, amount);
        token.transfer(collector, fee);  
        token.approve(address(tokenMessengerWithMetadata), amount-fee);

        if (destinationCaller == bytes32(0)) {
            tokenMessengerWithMetadata.depositForBurn(
                channel,
                destinationBech32Prefix,
                destinationRecipient,
                amount-fee,
                mintRecipient,
                burnToken,
                memo
            );
        } else {
            tokenMessengerWithMetadata.depositForBurnWithCaller(
                channel,
                destinationBech32Prefix,
                destinationRecipient,
                amount-fee,
                mintRecipient,
                burnToken,
                destinationCaller,
                memo
            );
        }

        emit Collect(burnToken, mintRecipient, amount-fee, fee, currentDomainId, uint32(4));
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
        require(allowedTokens[token] == true, "Token is not supported");
        
        // transfer to collector
        IMintBurnToken mintBurntoken = IMintBurnToken(token);
        mintBurntoken.transferFrom(msg.sender, contractAddress, amount);
        mintBurntoken.transfer(collector, amount);  

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
        require(allowedTokens[token] == true, "Token is not supported");
        
        // transfer to collector
        IMintBurnToken mintBurntoken = IMintBurnToken(token);
        mintBurntoken.transferFrom(msg.sender, contractAddress, amount);
        mintBurntoken.transfer(collector, amount);  

        // emit event
        emit FastTransferIBC(
            token,
            recipient,
            amount,
            currentDomainId,
            4,
            channel,
            destinationBech32Prefix,
            destinationRecipient,
            memo
        );
    }

    function updateTokenMessenger(address newTokenMessenger) external {
        require(msg.sender == owner, "unauthorized");
        tokenMessenger = TokenMessenger(newTokenMessenger);
    }

    function updateTokenMessengerWithMetadata(address newTokenMessenger) external {
        require(msg.sender == owner, "unauthorized");
        tokenMessengerWithMetadata = TokenMessengerWithMetadata(newTokenMessenger);
    }

    function calculateFee(uint256 amount, uint32 destinationDomain) private view returns (uint256) {
        Fee memory entry = feeMap[destinationDomain];
        require(entry.isInitialized, "Fee not found");
        uint256 fee = (amount * entry.percFee) / 10000 + entry.flatFee;
        require(amount > fee, "burn amount < fee");
        return fee;
    }

    function setFee(uint32 destinationDomain, uint256 percFee, uint256 flatFee) external {
        require(msg.sender == feeUpdater, "unauthorized");
        require(percFee <= 100, "can't set bips > 100"); // 1%
        feeMap[destinationDomain] = Fee(percFee, flatFee, true);
    }

    function updateOwner(address newOwner) external {
        require(msg.sender == owner, "unauthorized");
        owner = newOwner;
    }

    function updateCollector(address payable newCollector) external {
        require(msg.sender == owner, "unauthorized");
        collector = newCollector;
    }

    function updateFeeUpdater(address newFeeUpdater) external {
        require(msg.sender == owner, "unauthorized");
        feeUpdater = newFeeUpdater;
    }

    function allowAddress(address newAllowedAddress) external {
        require(msg.sender == owner, "unauthorized");
        allowedTokens[newAllowedAddress] = true;
    }

    function disallowAddress(address newDisallowedAddress) external {
        require(msg.sender == owner, "unauthorized");
        allowedTokens[newDisallowedAddress] = false;
    }
}
