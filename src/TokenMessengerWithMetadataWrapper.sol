// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.7.6;

import "evm-cctp-contracts/src/interfaces/IMintBurnToken.sol";
import "evm-cctp-contracts/src/TokenMessenger.sol";
import "lib/cctp-contracts/src/TokenMessengerWithMetadata.sol";

/**
 * @title TokenMessengerWithMetadataWrapper
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
contract TokenMessengerWithMetadataWrapper {
    // ============ Events ============
    event DepositForBurnMetadata(
        uint32 indexed currentDomainId, uint64 indexed nonce
    );
    event Collect(
        address indexed burnToken, 
        bytes32 mintRecipient, 
        uint256 indexed amountBurned, 
        uint256 indexed fee,
        uint32 source, 
        uint32 dest
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
        address payable _collector
    ) {
        require(_tokenMessenger != address(0), "TokenMessenger not set");
        tokenMessenger = TokenMessenger(_tokenMessenger);

        require(_tokenMessengerWithMetadata != address(0), "TMWithMetadata not set");
        tokenMessengerWithMetadata = TokenMessengerWithMetadata(_tokenMessengerWithMetadata);

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
        token.transferFrom(msg.sender, address(this), amount);
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
        token.transferFrom(msg.sender, address(this), amount);
        token.transfer(collector, fee);  
        token.approve(address(tokenMessengerWithMetadata), amount-fee);

        uint64 nonce;
        if (destinationCaller == bytes32(0)) {
            nonce = tokenMessengerWithMetadata.depositForBurn(
                channel,
                destinationBech32Prefix,
                destinationRecipient,
                amount-fee,
                mintRecipient,
                burnToken,
                memo
            );
        } else {
            nonce = tokenMessengerWithMetadata.depositForBurnWithCaller(
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
        emit DepositForBurnMetadata(currentDomainId, nonce);
    }


    function calculateFee(uint256 amount, uint32 destinationDomain) private view returns (uint256) {
        Fee memory entry = feeMap[destinationDomain];
        require(entry.isInitialized, "Fee not found");
        uint256 fee = (amount * entry.percFee) / 10000 + entry.flatFee;
        require(amount > fee, "burn amount is smaller than fee");
        return fee;
    }

    function setFee(uint32 destinationDomain, uint256 percFee, uint256 flatFee) external {
        require(msg.sender == owner, "unauthorized");
        require(percFee <= 10000, "can't set bips above 10000"); // 100.00%
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
}
