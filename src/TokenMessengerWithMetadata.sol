// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.7.6;

import "evm-cctp-contracts/src/interfaces/IMintBurnToken.sol";
import "evm-cctp-contracts/src/messages/Message.sol";
import "evm-cctp-contracts/src/MessageTransmitter.sol";
import "evm-cctp-contracts/src/TokenMessenger.sol";

/**
 * @title TokenMessengerWithMetadata
 * @notice A wrapper for a CCTP TokenMessenger contract that collects fees.
 * 
 * depositForBurnVanilla allows users to specify any destination domain.
 * 
 * The other 4 functions allow users to supply additional metadata when initiating a 
 * transfer. This metadata is used to initiate IBC forwards after transferring 
 * to Noble (Destination Domain = 4).  These contracts are:
 * 
 * depositForBurn
 * depositForBurnWithCaller
 * rawDepositForBurn
 * rawDepositForBurnWithCaller
 */
contract TokenMessengerWithMetadata {
    // ============ Events ============
    event DepositForBurnMetadata(
        uint64 indexed nonce, uint64 indexed metadataNonce, bytes metadata
    );
    event Collect(
        address indexed burnToken, 
        bytes32 mintRecipient, 
        uint256 amountBurned, 
        uint256 fee,
        uint32 source, 
        uint32 dest
    );

    // ============ State Variables ============
    TokenMessenger public tokenMessenger;
    MessageTransmitter public immutable messageTransmitter;

    // the domain id this contract is deployed on
    uint32 public immutable currentDomainId;
    // Noble's domain number
    uint32 public immutable nobleDomainId;
    // Address of Noble's message recipient on destination chain as bytes32
    bytes32 public immutable domainRecipient;
    // address which sets fees and collector
    address public owner;
    // address which fees are sent to
    address payable public collector; 

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
     * @param _nobleDomainId Noble's domain number
     * @param _domainRecipient Noble's domain recipient
     * @param _currentDomainId The domain id this contract is deployed on
     * @param _collector address which fees are sent to
     */
    constructor(
        address _tokenMessenger,
        uint32 _nobleDomainId,
        bytes32 _domainRecipient,
        uint32 _currentDomainId,
        address payable _collector
    ) {
        require(_tokenMessenger != address(0), "TokenMessenger not set");
        tokenMessenger = TokenMessenger(_tokenMessenger);
        messageTransmitter = MessageTransmitter(
            address(tokenMessenger.localMessageTransmitter())
        );

        nobleDomainId = _nobleDomainId;
        domainRecipient = _domainRecipient;
        currentDomainId = _currentDomainId;
        collector = _collector;
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
    function depositForBurnVanilla(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller
    ) external {
        uint256 fee = calculateFee(amount, destinationDomain);

        IMintBurnToken token = IMintBurnToken(burnToken);
        token.transferFrom(msg.sender, address(this), amount);

        // collect fee
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
     * Emits a `DepositForBurnMetadata` event.
     * Only for minting to Noble (destination domain is hardcoded).
     *
     * @param channel channel id to be used when ibc forwarding
     * @param destinationRecipient address of recipient once ibc forwarded
     * @param destinationBech32Prefix bech32 prefix used for address encoding once ibc forwarded
     * @param amount amount of tokens to burn
     * @param mintRecipient address of mint recipient on destination domain
     * @param burnToken address of contract to burn deposited tokens, on local domain
     * @param memo arbitrary memo to be included when ibc forwarding
     * @return nonce unique nonce reserved by message
     */
    function depositForBurn(
        uint64 channel,
        bytes32 destinationBech32Prefix,
        bytes32 destinationRecipient,
        uint256 amount,
        bytes32 mintRecipient,
        address burnToken,
        bytes calldata memo
    ) external returns (uint64 nonce) {
        uint64 reservedNonce = messageTransmitter.nextAvailableNonce();
        bytes32 sender = Message.addressToBytes32(msg.sender);
        bytes memory metadata = abi.encodePacked(
            reservedNonce,
            sender,
            channel,
            destinationBech32Prefix,
            destinationRecipient,
            memo
        );

        return rawDepositForBurn(amount, mintRecipient, burnToken, metadata);
    }

    /**
     * @notice Wrapper function for "depositForBurn" that includes metadata.
     * Emits a `DepositForBurnMetadata` event.
     * Only for minting to Noble (destination domain is hardcoded).
     * 
     * @param amount amount of tokens to burn
     * @param mintRecipient address of mint recipient on destination domain
     * @param burnToken address of contract to burn deposited tokens, on local domain
     * @param metadata custom metadata to be included with transfer
     * @return nonce unique nonce reserved by message
     */
    function rawDepositForBurn(
        uint256 amount,
        bytes32 mintRecipient,
        address burnToken,
        bytes memory metadata
    ) public returns (uint64 nonce) {
        uint256 fee = calculateFee(amount, nobleDomainId);

        IMintBurnToken token = IMintBurnToken(burnToken);
        token.transferFrom(msg.sender, address(this), amount);

        // collect fee
        token.transfer(collector, fee);  

        token.approve(address(tokenMessenger), amount-fee);

        nonce = tokenMessenger.depositForBurn(
            amount-fee, nobleDomainId, mintRecipient, burnToken
        );

        uint64 metadataNonce = messageTransmitter.sendMessage(
            nobleDomainId, domainRecipient, metadata
        );

        emit Collect(burnToken, mintRecipient, amount-fee, fee, currentDomainId, nobleDomainId);
        emit DepositForBurnMetadata(nonce, metadataNonce, metadata);
    }

    /**
     * @notice Wrapper function for "depositForBurnWithCaller" that includes metadata.
     * Emits a `DepositForBurnMetadata` event.
     * Only for minting to Noble (destination domain is hardcoded).
     * 
     * @param channel channel id to be used when ibc forwarding
     * @param destinationRecipient address of recipient once ibc forwarded
     * @param destinationBech32Prefix bech32 prefix used for address encoding once ibc forwarded
     * @param amount amount of tokens to burn
     * @param mintRecipient address of mint recipient on destination domain
     * @param burnToken address of contract to burn deposited tokens, on local domain
     * @param destinationCaller caller on the destination domain, as bytes32
     * @param memo arbitrary memo to be included when ibc forwarding
     * @return nonce unique nonce reserved by message
     */
    function depositForBurnWithCaller(
        uint64 channel,
        bytes32 destinationBech32Prefix,
        bytes32 destinationRecipient,
        uint256 amount,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        bytes calldata memo
    ) external returns (uint64 nonce) {
        uint64 reservedNonce = messageTransmitter.nextAvailableNonce();
        bytes32 sender = Message.addressToBytes32(msg.sender);
        bytes memory metadata = abi.encodePacked(
            reservedNonce,
            sender,
            channel,
            destinationBech32Prefix,
            destinationRecipient,
            memo
        );

        return rawDepositForBurnWithCaller(
            amount, mintRecipient, burnToken, destinationCaller, metadata
        );
    }

    /**
     * @notice Wrapper function for "depositForBurnWithCaller" that includes metadata.
     * Emits a `DepositForBurnMetadata` event.
     * Only for minting to Noble (destination domain is hardcoded).
     * 
     * @param amount amount of tokens to burn
     * @param mintRecipient address of mint recipient on destination domain
     * @param burnToken address of contract to burn deposited tokens, on local domain
     * @param destinationCaller caller on the destination domain, as bytes32
     * @param metadata custom metadata to be included with transfer
     * @return nonce unique nonce reserved by message
     */
    function rawDepositForBurnWithCaller(
        uint256 amount,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        bytes memory metadata
    ) public returns (uint64 nonce) {
        uint256 fee = calculateFee(amount, nobleDomainId);

        IMintBurnToken token = IMintBurnToken(burnToken);
        token.transferFrom(msg.sender, address(this), amount);

        // collect fee
        token.transfer(collector, fee);

        token.approve(address(tokenMessenger), amount-fee);

        nonce = tokenMessenger.depositForBurnWithCaller(
            amount, nobleDomainId, mintRecipient, burnToken, destinationCaller
        );

        uint64 metadataNonce = messageTransmitter.sendMessageWithCaller(
            nobleDomainId, domainRecipient, destinationCaller, metadata
        );

        emit Collect(burnToken, mintRecipient, amount-fee, fee, currentDomainId, nobleDomainId);
        emit DepositForBurnMetadata(nonce, metadataNonce, metadata);
    }

    function calculateFee(uint256 amount, uint32 destinationDomain) private view returns (uint256) {
        Fee memory entry = feeMap[destinationDomain];
        require(entry.isInitialized, "Fee not found");
        uint256 fee = (amount * entry.percFee) / 10000 + entry.flatFee;
        require(amount > fee, "burn amount is smaller than fee");
        return fee;
    }

    function setFee(uint32 destinationDomain, uint256 percFee, uint256 flatFee) external {
        require(msg.sender == owner, "Only owner can update fees");
        require(percFee <= 10000, "can't set bips above 10000"); // 100.00%
        feeMap[destinationDomain] = Fee(percFee, flatFee, true);
    }

    function updateOwner(address newOwner) external {
        require(msg.sender == owner, "Only owner can update owner");
        owner = newOwner;
    }

    function updateCollector(address payable newCollector) external {
        require(msg.sender == owner, "Only owner can update collector");
        collector = newCollector;
    }
}
