//SPDX-License-Identifier: UNLICENSED

pragma solidity 0.7.6;

import "./interfaces/ITokenMessenger.sol";
import "./interfaces/ITokenMessengerWithMetadata.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "evm-cctp-contracts/src/interfaces/IMintBurnToken.sol";

/**
 * This contract collects fees and wraps 6 external contract functions.
 * 
 * depositForBurn - a normal burn
 * depositForBurnWithCaller - only the destination caller address can mint
 * 
 * We can also specify metadata for minting on Noble and forwarding to an IBC connected chain:
 * 
 * depositForBurnWithMetadata - explicit parameters
 * rawDepositForBurnWithMetadata - paramaters are packed into a byte array
 * depositForBurnWithCallerWithMetadata - explicit parameters with destination caller
 * rawDepositForBurnWithCallerWithMetadata - byte array parameters with destination caller
 */
contract Deposit {

    // an address that is used to update parameters
    address public owner;

    // the address where fees are sent
    address payable public collector;

    // the domain id this contract is deployed on
    uint32 public immutable domain;

    // Noble domain id
    uint32 public immutable nobleDomainId = 4;

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

    // cctp token messenger contract
    ITokenMessenger public tokenMessenger;

    // ibc forwarding wrapper contract
    ITokenMessengerWithMetadata public tokenMessengerWithMetadata;

    // TODO the event should have everything we need to mint on destination chain
    event Burn(address sender, uint32 source, uint32 dest, address indexed token, uint256 indexed amountBurned, uint256 indexed fee);

    // TODO whitelist of tokens that can be burnt?

    event Debug(string msg);
    
    constructor(
        address _tokenMessenger, 
        address _tokenMessengerWithMetadata, 
        address payable _collector,
        uint32 _domain) {

        require(_tokenMessenger != address(0), "TokenMessenger not set");
        tokenMessenger = ITokenMessenger(_tokenMessenger);

        require(_tokenMessengerWithMetadata != address(0), "TokenMessengerWithMetadata not set");
        tokenMessengerWithMetadata = ITokenMessengerWithMetadata(_tokenMessengerWithMetadata);

        collector = _collector;
        domain = _domain;

        owner = msg.sender;
    }

    /**
     * Burns the token on the source chain.
     * 
     * Wraps TokenMessenger.depositForBurn
     * 
     * @param amount asdf
     * @param destinationDomain  asdf
     * @param mintRecipient  asdf
     * @param burnToken asdf
     */
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken
    ) external {

        IMintBurnToken token = IMintBurnToken(burnToken);
        token.transferFrom(msg.sender, address(this), amount);
        token.approve(address(tokenMessenger), amount);

        uint256 fee = calculateFee(amount, destinationDomain);

        token.transferFrom(address(this), collector, fee);

        tokenMessenger.depositForBurn(amount - fee, destinationDomain, mintRecipient, burnToken);
        emit Burn(msg.sender, domain, destinationDomain, burnToken, amount - fee, fee);
    }

    /**
     * Burns the token on the source chain
     * Specifies an address which can mint
     * 
     * Wraps TokenMessenger.depositForBurnWithCaller
     * 
     * @param amount asdf
     * @param destinationDomain  asdf
     * @param mintRecipient  asdf
     * @param burnToken asdf
     * @param destinationCaller asdf
     */
    function depositForBurnWithCaller(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller
    ) external {
        uint256 fee = calculateFee(amount, destinationDomain);
        IERC20(burnToken).transferFrom(msg.sender, collector, fee);

        tokenMessenger.depositForBurnWithCaller(
            amount - fee, 
            destinationDomain, 
            mintRecipient, 
            burnToken, 
            destinationCaller
        );

        emit Burn(msg.sender, domain, destinationDomain, burnToken, amount - fee, fee);
    }

    /**
     * Only for depositing to an IBC connected chain via Noble
     * 
     * Burns tokens on the source chain
     * Includes IBC forwarding instructions
     * @param channel  asdf
     * @param destinationRecipient adsf
     * @param amount asdf
     * @param mintRecipient asdf
     * @param burnToken asdf
     * @param memo sdf
     */
    function depositForBurnWithMetadata(
        uint64 channel,
        bytes32 destinationRecipient,
        uint256 amount, 
        bytes32 mintRecipient, 
        address burnToken,
        bytes calldata memo
    ) external {
        uint256 fee = calculateFee(amount, nobleDomainId);
        IERC20(burnToken).transferFrom(msg.sender, collector, fee);
        
        tokenMessengerWithMetadata.depositForBurn(
            channel,
            destinationRecipient,
            amount - fee,
            mintRecipient,
            burnToken,
            memo
        );

        emit Burn(msg.sender, domain, nobleDomainId, burnToken, amount - fee, fee);
    }

    /**
     * Only for depositing to an IBC connected chain via Noble
     * 
     * Burns tokens on the source chain
     * Includes IBC forwarding instructions
     */
    function rawDepositForBurnWithMetadata(
        uint256 amount, 
        bytes32 mintRecipient, 
        address burnToken,
        bytes memory metadata
    ) external {
        uint256 fee = calculateFee(amount, nobleDomainId);
        IERC20(burnToken).transferFrom(msg.sender, collector, fee);
        
        tokenMessengerWithMetadata.rawDepositForBurn(
            amount - fee,
            mintRecipient,
            burnToken,
            metadata
        );

        emit Burn(msg.sender, domain, nobleDomainId, burnToken, amount - fee, fee);
    }

    /**
     * Only for depositing to an IBC connected chain via Noble
     * 
     * Burns tokens on the source chain
     * Specifies an address which can mint
     * Includes IBC forwarding instructions
     * 
     * @param channel  asdf
     * @param destinationRecipient adsf
     * @param amount asdf
     * @param mintRecipient asdf
     * @param burnToken asdf
     * @param destinationCaller asdf
     * @param memo sdf
     */
    function depositForBurnWithCallerWithMetadata(
        uint64 channel,
        bytes32 destinationRecipient,
        uint256 amount, 
        bytes32 mintRecipient, 
        address burnToken,
        bytes32 destinationCaller,
        bytes calldata memo
    ) external {
        uint256 fee = calculateFee(amount, nobleDomainId);
        IERC20(burnToken).transferFrom(msg.sender, collector, fee);
        
        tokenMessengerWithMetadata.depositForBurnWithCaller(
            channel,
            destinationRecipient,
            amount - fee,
            mintRecipient,
            burnToken,
            destinationCaller,
            memo
        );

        emit Burn(msg.sender, domain, nobleDomainId, burnToken, amount - fee, fee);
    }

   /**
    * Only for depositing to an IBC connected chain via Noble
    * 
    * Burns tokens on the source chain
    * Specifies an address which can mint
    * Includes IBC forwarding instructions
    * 
    * @param amount asdf
    * @param mintRecipient asdf
    * @param burnToken asdf
    * @param destinationCaller asdf
    * @param metadata asdf
    */
    function rawDepositForBurnWithCallerWithMetadata(
        uint256 amount, 
        bytes32 mintRecipient, 
        address burnToken,
        bytes32 destinationCaller,
        bytes memory metadata
    ) external {
        uint256 fee = calculateFee(amount, nobleDomainId);
        IERC20(burnToken).transferFrom(msg.sender, collector, fee);
        
        tokenMessengerWithMetadata.rawDepositForBurnWithCaller(
            amount - fee,
            mintRecipient,
            burnToken,
            destinationCaller,
            metadata
        );

        emit Burn(msg.sender, domain, nobleDomainId, burnToken, amount - fee, fee);
    }

    function calculateFee(uint256 amount, uint32 destinationDomain) private view returns (uint256) {
        Fee memory fee = feeMap[destinationDomain];
        require(fee.isInitialized, "Fee not found.");
        return (amount * fee.percFee) + fee.flatFee;
    }

    function updateOwner(address newOwner) external {
        require(msg.sender == owner, "Only the owner can update the owner");
        owner = newOwner;
    }

    function updateCollector(address payable newCollector) external {
        require(msg.sender == owner, "Only the owner can update the collector");
        collector = newCollector;
    }

    function updateFee(uint32 destinationDomain, uint256 percFee, uint256 flatFee) external {
        require(msg.sender == owner, "Only the owner can update fees");
        feeMap[destinationDomain] = Fee(percFee, flatFee, true);
    }
}