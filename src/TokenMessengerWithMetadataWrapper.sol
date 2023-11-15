// SPDX-License-Identifier: Apache-2.0
// AUDIT: use 0.8.22 with evm_version = paris
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
    // AUDIT: indexed events cost quite a bit extra gas, do we really need `amountBurned` to be indexed? i.e. will you ever make an eth_getLogs query filtering by a specific amount?
    // rule of thumb is only if you need to filter by a field should it be indexed.. also you can generally index quite easily off chain especially with relatively low volume events
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
    // AUDIT: do we ever actually plan on updating these? can save a lot of gas by making them immutable
    TokenMessenger public tokenMessenger;
    TokenMessengerWithMetadata public tokenMessengerWithMetadata;

    // the domain id this contract is deployed on
    uint32 public immutable currentDomainId;
    // address which sets fees and collector
    // AUDIT: consider using an Owned library for readability like https://github.com/transmissions11/solmate/blob/main/src/auth/Owned.sol
    address public owner;
    // address which fees are sent to
    address payable public collector;
    // address which can update fees
    // AUDIT: why is feeUpdate != owner?
    address public feeUpdater;
    // current contract address (gas optimiation)
    address public immutable contractAddress;

    // fast transfer - allowed erc20 tokens
    // AUDIT: isn't it always just USDC?
    mapping(address => bool) public allowedTokens;

    struct Fee {
        // AUDIT: you definitely dont need 256 bits for the fee bps, max is 10,000 so you can get away with a uint16
        // this will pack the struct into a single slot to save you a few thousand gas per read
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
        // AUDIT: only need payable if sending ETH, you're only ever sending it USDC afaict
        address payable _collector,
        address _feeUpdater
    ) {
        // AUDIT: custom errors for readability and gas savings
        // i.e. defined as `error TokenMessengerNotSet();`
        // thrown as `revert TokenMessengerNotSet();`
        require(_tokenMessenger != address(0), "TokenMessenger not set");
        tokenMessenger = TokenMessenger(_tokenMessenger);

        require(_tokenMessengerWithMetadata != address(0), "TMWithMetadata not set");
        tokenMessengerWithMetadata = TokenMessengerWithMetadata(_tokenMessengerWithMetadata);

        // AUDIT: is this actually a gas optimization? reading address(this) is literally 2 gas
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
        // AUDIT: wait isn't the token always USDC? Can you just take the USDC address as a constructor param?
        address burnToken,
        bytes32 destinationCaller
    ) external {
        // collect fee
        uint256 fee = calculateFee(amount, destinationDomain);
        IMintBurnToken token = IMintBurnToken(burnToken);
        token.transferFrom(msg.sender, contractAddress, amount);
        // AUDIT(gas): escrow fees in this contract and exposing a withdrawFees function only callable by collector
        token.transfer(collector, fee);
        // AUDIT: we trust tokenMessenger fully right? Could we just do this as a one-time max approve instead?
        // i.e. in the constructor or when adding new token do `token.approve(tokenMessenger, type(uint256).max)`
        token.approve(address(tokenMessenger), amount-fee);

        if (destinationCaller == bytes32(0)) {
            tokenMessenger.depositForBurn(
                // AUDIT: nit but precalculate amount - fee and save into a local since you use it multiple times
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
        // AUDIT: nit - noble domain id as a constant
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
        // AUDIT: this is sooo sus for a user lmao
        // I'd strongly recommend an escrow + unlock approach
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
