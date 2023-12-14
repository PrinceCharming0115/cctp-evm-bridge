pragma solidity 0.8.22;

import "evm-cctp-contracts/src/TokenMessenger.sol";
import "evm-cctp-contracts/src/messages/Message.sol";
import "evm-cctp-contracts/src/messages/BurnMessage.sol";
import "evm-cctp-contracts/src/MessageTransmitter.sol";
import "evm-cctp-contracts/test/TestUtils.sol";
import "../src/TokenMessengerWithMetadataWrapper.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {SigUtils} from "./utils/SigUtils.sol";

contract PermitTest is Test, TestUtils, GasSnapshot {
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
    uint32 public constant LOCAL_DOMAIN = 0;
    uint32 public constant MESSAGE_BODY_VERSION = 1;

    uint32 public constant REMOTE_DOMAIN = 4;
    bytes32 public constant REMOTE_TOKEN_MESSENGER =
        0x00000000000000000000000057d4eaf1091577a6b7d121202afbd2808134f117;

    address public constant OWNER = address(0x1);
    address public constant COLLECTOR = address(0x2);
    address public constant FEE_UPDATER = address(0x3);
    address public constant TOKEN_ADDRESS = address(0x4);

    uint32 public constant ALLOWED_BURN_AMOUNT = 42000000;
    MockERC20 public token;
    SigUtils public sigUtils;
    TokenMinter public tokenMinter = new TokenMinter(tokenController);

    MessageTransmitter public messageTransmitter = new MessageTransmitter(
            LOCAL_DOMAIN,
            attester,
            maxMessageBodySize,
            version
        );

    TokenMessenger public tokenMessenger;
    TokenMessengerWithMetadata public tokenMessengerWithMetadata;
    TokenMessengerWithMetadataWrapper public tokenMessengerWithMetadataWrapper;

    // ============ Setup ============
    function setUp() public {
        token = new MockERC20();
        sigUtils = new SigUtils(token.DOMAIN_SEPARATOR());

        tokenMessenger = new TokenMessenger(
            address(messageTransmitter),
            MESSAGE_BODY_VERSION
        );
        tokenMessengerWithMetadata = new TokenMessengerWithMetadata(
            address(tokenMessenger),
            4,
            bytes32(0x00000000000000000000000057d4eaf1091577a6b7d121202afbd2808134f117)
        );

        vm.prank(OWNER);
        tokenMessengerWithMetadataWrapper = new TokenMessengerWithMetadataWrapper(
            address(tokenMessenger),
            address(tokenMessengerWithMetadata),
            LOCAL_DOMAIN,
            COLLECTOR,
            FEE_UPDATER,
            address(token)
        );

        vm.prank(FEE_UPDATER);
        tokenMessengerWithMetadataWrapper.setFee(REMOTE_DOMAIN, 0, 0);

        tokenMessenger.addLocalMinter(address(tokenMinter));
        tokenMessenger.addRemoteTokenMessenger(REMOTE_DOMAIN, REMOTE_TOKEN_MESSENGER);

        linkTokenPair(tokenMinter, address(token), REMOTE_DOMAIN, REMOTE_TOKEN_MESSENGER);
        tokenMinter.addLocalTokenMessenger(address(tokenMessenger));

        vm.prank(tokenController);
        tokenMinter.setMaxBurnAmountPerMessage(
            address(token), ALLOWED_BURN_AMOUNT
        );
    }

    // ============ Tests ============

    // depositForBurn
    function testDepositForBurnPermitSuccess(
        uint256 _amount
    ) public {

        snapStart("depositForBurnSuccess");

        vm.assume(_amount > 0);
        vm.assume(_amount <= ALLOWED_BURN_AMOUNT);

        vm.prank(FEE_UPDATER);
        tokenMessengerWithMetadataWrapper.setFee(REMOTE_DOMAIN, 0, 0);

        //vm.expectEmit(true, true, true, true);
        uint256 fee = 0;
        //emit Collect(_mintRecipientRaw, _amount - fee, fee, LOCAL_DOMAIN, REMOTE_DOMAIN);

        // max permit
        uint256 ownerPrivateKey = 0xA11CE;
        address owner = vm.addr(ownerPrivateKey);
        token.mint(owner, _amount);

        SigUtils.Permit memory permit = SigUtils.Permit({
            owner: owner,
            spender: address(tokenMessengerWithMetadataWrapper),
            value: type(uint256).max,
            nonce: token.nonces(owner),
            deadline: 1 days
        });

        bytes32 digest = sigUtils.getTypedDataHash(permit);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        tokenMessengerWithMetadataWrapper.depositForBurnPermit(
            _amount,
            REMOTE_DOMAIN,
            Message.addressToBytes32(address(0x10)),
            bytes32(0),
            permit.deadline,
            v,
            r,
            s
        );

        assertEq(0, token.balanceOf(OWNER));
        assertEq(fee, token.balanceOf(address(tokenMessengerWithMetadataWrapper)));

        snapEnd();
    }
}
