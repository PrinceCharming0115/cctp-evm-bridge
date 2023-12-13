pragma solidity 0.8.22;

import "lib/evm-cctp-contracts/src/TokenMessenger.sol";
import "lib/cctp-contracts/src/TokenMessengerWithMetadata.sol";
import "lib/solmate/src/auth/Owned.sol";

/**
 * @title TokenMessengerWithMetadataWrapper
 * @notice A wrapper for a CCTP TokenMessengerWithMetadata contract that collects fees from USDC transfers.
 *  This contract -> TokenMessengerWithMetadata -> TokenMessenger
 *
 * depositForBurn allows users to specify any destination domain.
 * depositForBurnIBC is for minting and forwarding from Noble.
 *  It allows users to supply additional IBC forwarding metadata after initiating a transfer to Noble.
 * 
 */
contract TokenMessengerWithMetadataWrapper is Owned(msg.sender) {
    // ============ Events ============
    event Collect(
        bytes32 mintRecipient,
        uint256 amountBurned, 
        uint256 fee,
        uint32 source,
        uint32 dest
    );
    
    // ============ Errors ============
    error TokenMessengerNotSet();
    error TokenNotSupported();
    error FeeNotFound();
    error BurnAmountTooLow();
    error Unauthorized();
    error PercFeeTooHigh();
    
    // ============ State Variables ============
    // Circle contract for burning tokens
    TokenMessenger public immutable tokenMessenger;
    // Noble contract for including IBC forwarding metadata
    TokenMessengerWithMetadata public tokenMessengerWithMetadata;
    // the domain id this contract is deployed on
    uint32 public immutable currentDomainId;
    // noble domain id
    uint32 public constant nobleDomainId = 4;
    // address that can collect fees
    address public collector;
    // address that can update fees
    address public feeUpdater;
    // USDC address for this domain
    address public immutable tokenAddress;

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
     * @param _tokenAddress USDC erc20 token address for this domain
     */
    constructor(
        address _tokenMessenger,
        address _tokenMessengerWithMetadata,
        uint32 _currentDomainId,
        address _collector,
        address _feeUpdater,
        address _tokenAddress
    ) {
        if (_tokenMessenger == address(0)) {
            revert TokenMessengerNotSet();
        }
        tokenMessenger = TokenMessenger(_tokenMessenger);
        tokenMessengerWithMetadata = TokenMessengerWithMetadata(_tokenMessengerWithMetadata);

        currentDomainId = _currentDomainId;
        collector = _collector;
        feeUpdater = _feeUpdater;
        tokenAddress = _tokenAddress;

        IERC20 token = IERC20(tokenAddress);
        token.approve(_tokenMessenger, type(uint256).max);
        token.approve(_tokenMessengerWithMetadata, type(uint256).max);
    }

    // ============ External Functions ============
    /**
     * @notice Wrapper function for TokenMessenger.depositForBurn() and .depositForBurnWithCaller()
     * If destinationCaller is empty, call "depositForBurnWithCaller", otherwise call "depositForBurn".
     * Can specify any destination domain, including invalid ones.  Only for USDC.
     *
     * @param amount - the burn amount
     * @param destinationDomain - domain id the funds will be minted on
     * @param mintRecipient - address receiving minted tokens on destination domain
     * @param destinationCaller - address allowed to mint on destination chain
     */
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        bytes32 destinationCaller
    ) external {
        // collect fee
        uint256 fee;
        uint256 remainder;
        (fee, remainder) = calculateFee(amount, destinationDomain);

        IERC20 token = IERC20(tokenAddress);
        token.transferFrom(msg.sender, address(this), amount);

        if (destinationCaller == bytes32(0)) {
            tokenMessenger.depositForBurn(
                remainder,
                destinationDomain,
                mintRecipient,
                tokenAddress
            );
        } else {
            tokenMessenger.depositForBurnWithCaller(
                remainder,
                destinationDomain,
                mintRecipient,
                tokenAddress,
                destinationCaller
            );
        }
        emit Collect(mintRecipient, remainder, fee, currentDomainId, destinationDomain);
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
     * @param memo arbitrary memo to be included when ibc forwarding
     */
    function depositForBurnIBC(
        uint64 channel,
        bytes32 destinationBech32Prefix,
        bytes32 destinationRecipient,
        uint256 amount,
        bytes32 mintRecipient,
        bytes32 destinationCaller,
        bytes calldata memo
    ) external {
        // collect fee
        uint256 fee;
        uint256 remainder;
        (fee, remainder) = calculateFee(amount, nobleDomainId);

        IERC20 token = IERC20(tokenAddress);
        token.transferFrom(msg.sender, address(this), amount);

        if (destinationCaller == bytes32(0)) {
            tokenMessengerWithMetadata.depositForBurn(
                channel,
                destinationBech32Prefix,
                destinationRecipient,
                remainder,
                mintRecipient,
                tokenAddress,
                memo
            );
        } else {
            tokenMessengerWithMetadata.depositForBurnWithCaller(
                channel,
                destinationBech32Prefix,
                destinationRecipient,
                remainder,
                mintRecipient,
                tokenAddress,
                destinationCaller,
                memo
            );
        }

        emit Collect(mintRecipient, remainder, fee, currentDomainId, nobleDomainId);
    }

    function updateTokenMessengerWithMetadata(address newTokenMessengerWithMetadata) external onlyOwner {
        IERC20 token = IERC20(tokenAddress);
        token.approve(address(tokenMessengerWithMetadata), 0);

        tokenMessengerWithMetadata = TokenMessengerWithMetadata(newTokenMessengerWithMetadata);
        token.approve(newTokenMessengerWithMetadata, type(uint256).max);
    }

    function calculateFee(uint256 amount, uint32 destinationDomain) private view returns (uint256, uint256) {
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

    /**
     * Set fee for a given destination domain.
     */
    function setFee(uint32 destinationDomain, uint16 percFee, uint64 flatFee) external {
        if (msg.sender != feeUpdater) {
            revert Unauthorized();
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

    function withdrawFees() external {
        if (msg.sender != collector) {
            revert Unauthorized();
        }
        uint256 balance = IERC20(tokenAddress).balanceOf(address(this));
        IERC20 token = IERC20(tokenAddress);
        token.transfer(collector, balance);
    }
}
