// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.7.6;

import "evm-cctp-contracts/src/MessageTransmitter.sol";
import "evm-cctp-contracts/src/interfaces/IMintBurnToken.sol";
import "evm-cctp-contracts/src/messages/Message.sol";
import "evm-cctp-contracts/src/TokenMessenger.sol";

/**
 * @title TokenMessengerWithMetadata
 * @notice A wrapper for a CCTP TokenMessenger contract that allows users to
 * supply additional metadata when initiating a transfer. This metadata is used
 * to initiate IBC forwards after transferring to Noble (Destination Domain = 4).
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
    // TODO
    event Debug(string tag, uint256 amount);

    // ============ State Variables ============
    TokenMessenger public tokenMessenger;
    MessageTransmitter public immutable messageTransmitter;

    uint32 public immutable domainNumber;
    bytes32 public immutable domainRecipient;

    // the address that can update parameters
    address public owner;
    // the address where fees are sent
    address payable public collector; 

    struct Fee {
        // percentage fee in bips
        uint256 percFee;
        // flat fee in uusdc (1 uusdc = 10^-6 usdc)
        uint256 flatFee;
        // needed for null check
        bool isInitialized;
    }
    
    // mapping of destination domain -> fee
    mapping(uint32 => Fee) public feeMap;

    // the domain id this contract is deployed on
    uint32 public immutable domain;

    // ============ Constructor ============
    /**
     * @param _tokenMessenger Token messenger address
     * @param _domainNumber Noble's domain number
     * @param _domainRecipient Noble's domain recipient
     * @param _domain The domain id this contract is deployed on
     */
    constructor(
        address _tokenMessenger,
        uint32 _domainNumber,
        bytes32 _domainRecipient,
        uint32 _domain,
        address payable _collector
    ) {
        require(_tokenMessenger != address(0), "TokenMessenger not set");
        tokenMessenger = TokenMessenger(_tokenMessenger);
        messageTransmitter = MessageTransmitter(
            address(tokenMessenger.localMessageTransmitter())
        );

        domainNumber = _domainNumber;
        domainRecipient = _domainRecipient;
        domain = _domain;
        collector = _collector;
        owner = msg.sender;
    }

    // ============ External Functions ============
    /**
     * @notice Wrapper function.
     * If destinationCaller is empty, call "depositForBurnWithCaller", otherwise call "depositForBurn"
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

        IMintBurnToken token = IMintBurnToken(burnToken);
        token.transferFrom(msg.sender, address(this), amount);
        token.approve(address(tokenMessenger), amount);

        // collect fee
        uint256 fee = calculateFee(amount, domainNumber);
        token.transfer(collector, fee);

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
        emit Collect(burnToken, mintRecipient, amount-fee, fee, domain, domainNumber);
    }

    /**
     * @notice Wrapper function for "depositForBurn" that includes metadata.
     * Emits a `DepositForBurnMetadata` event.
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
        IMintBurnToken token = IMintBurnToken(burnToken);
        token.transferFrom(msg.sender, address(this), amount);
        token.approve(address(tokenMessenger), amount);

        // collect fee
        uint256 fee = calculateFee(amount, domainNumber);
        token.transfer(collector, fee);  

        nonce = tokenMessenger.depositForBurn(
            amount-fee, domainNumber, mintRecipient, burnToken
        );

        uint64 metadataNonce = messageTransmitter.sendMessage(
            domainNumber, domainRecipient, metadata
        );

        emit Collect(burnToken, mintRecipient, amount-fee, fee, domain, domainNumber);
        emit DepositForBurnMetadata(nonce, metadataNonce, metadata);
    }

    /**
     * @notice Wrapper function for "depositForBurnWithCaller" that includes metadata.
     * Emits a `DepositForBurnMetadata` event.
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
        IMintBurnToken token = IMintBurnToken(burnToken);
        token.transferFrom(msg.sender, address(this), amount);
        token.approve(address(tokenMessenger), amount);

        // collect fee
        uint256 fee = calculateFee(amount, domainNumber);
        emit Debug("amount", amount);
        emit Debug("fee", fee);
        token.transfer(collector, fee);
        emit Collect(burnToken, mintRecipient, amount-fee, fee, domain, domainNumber);

        nonce = tokenMessenger.depositForBurnWithCaller(
            amount, domainNumber, mintRecipient, burnToken, destinationCaller
        );

        uint64 metadataNonce = messageTransmitter.sendMessageWithCaller(
            domainNumber, domainRecipient, destinationCaller, metadata
        );

        emit Collect(burnToken, mintRecipient, amount-fee, fee, domain, domainNumber);
        emit DepositForBurnMetadata(nonce, metadataNonce, metadata);
    }

    function calculateFee(uint256 amount, uint32 destinationDomain) private view returns (uint256) {
        Fee memory fee = feeMap[destinationDomain];
        require(fee.isInitialized, "Fee not found.");
        return (amount * fee.percFee) / 10000 + fee.flatFee;
    }

    function setFee(uint32 destinationDomain, uint256 percFee, uint256 flatFee) external {
        require(msg.sender == owner, "Only the owner can update fees");
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
