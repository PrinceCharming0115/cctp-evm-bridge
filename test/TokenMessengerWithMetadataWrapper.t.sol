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

contract TokenMessengerWithMetadataWrapperTest is Test, TestUtils, GasSnapshot {
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
        tokenMessenger.addRemoteTokenMessenger(
            REMOTE_DOMAIN, REMOTE_TOKEN_MESSENGER
        );

        linkTokenPair(tokenMinter, address(token), REMOTE_DOMAIN, REMOTE_TOKEN_MESSENGER);
        tokenMinter.addLocalTokenMessenger(address(tokenMessenger));

        vm.prank(tokenController);
        tokenMinter.setMaxBurnAmountPerMessage(
            address(token), ALLOWED_BURN_AMOUNT
        );
    }

    // ============ Tests ============
    function testConstructor_rejectsZeroAddressTokenMessenger() public {
        vm.expectRevert(TokenMessengerNotSet.selector);

        tokenMessengerWithMetadataWrapper = new TokenMessengerWithMetadataWrapper(
            address(0),
            address(address(tokenMessengerWithMetadata)),
            LOCAL_DOMAIN,
            COLLECTOR,
            FEE_UPDATER,
            TOKEN_ADDRESS
        );
    }

    // depositForBurn - no fee set
    function testDepositForBurnFeeNotFound(
        uint256 _amount
    ) public {
        _amount = 4;

        bytes32 _mintRecipient = Message.addressToBytes32(address(0x10));

        token.mint(OWNER, _amount);
        vm.prank(FEE_UPDATER);
        tokenMessengerWithMetadataWrapper.setFee(REMOTE_DOMAIN, 0, 3);

        tokenMessenger.addRemoteTokenMessenger(
            55, REMOTE_TOKEN_MESSENGER
        );

        vm.prank(OWNER);
        token.approve(address(tokenMessengerWithMetadataWrapper), _amount);

        vm.expectRevert(FeeNotFound.selector);

        vm.prank(OWNER);
        tokenMessengerWithMetadataWrapper.depositForBurn(
            _amount,
            55,
            _mintRecipient
        );
    }

    function testDepositForBurnWithTooSmallAmount(
        uint256 _amount,
        address _mintRecipient
    ) public {
        _amount = 2;

        vm.assume(_mintRecipient != address(0));
        bytes32 _mintRecipientRaw = Message.addressToBytes32(_mintRecipient);

        token.mint(OWNER, _amount);
        vm.prank(FEE_UPDATER);
        tokenMessengerWithMetadataWrapper.setFee(REMOTE_DOMAIN, 0, 3);

        vm.prank(OWNER);
        token.approve(address(tokenMessengerWithMetadataWrapper), _amount);

        vm.expectRevert(BurnAmountTooLow.selector);

        vm.prank(OWNER);
        tokenMessengerWithMetadataWrapper.depositForBurn(
            _amount,
            REMOTE_DOMAIN,
            _mintRecipientRaw
        );
    }

    // depositForBurn
    function testDepositForBurnSuccess(
        uint256 _amount,
        uint64 _flatFee,
        uint16 _percFee
    ) public {

        snapStart("depositForBurnSuccess");

        vm.assume(_amount > 0);
        vm.assume(_amount <= ALLOWED_BURN_AMOUNT);
        vm.assume(_percFee > 0);
        vm.assume(_percFee <= 100);
        vm.assume(_flatFee + _percFee * _amount / 10000 < _amount);

        bytes32 _mintRecipientRaw = Message.addressToBytes32(address(0x10));

        token.mint(OWNER, _amount);
        vm.prank(FEE_UPDATER);
        tokenMessengerWithMetadataWrapper.setFee(REMOTE_DOMAIN, _percFee, _flatFee);

        vm.prank(OWNER);
        token.approve(address(tokenMessengerWithMetadataWrapper), _amount);

        vm.expectEmit(true, true, true, true);
        uint256 fee = (_amount * _percFee / 10000) + _flatFee;
        emit Collect(_mintRecipientRaw, _amount - fee, fee, LOCAL_DOMAIN, REMOTE_DOMAIN);

        vm.prank(OWNER);
        tokenMessengerWithMetadataWrapper.depositForBurn(
            _amount,
            REMOTE_DOMAIN,
            _mintRecipientRaw
        );

        assertEq(0, token.balanceOf(OWNER));
        assertEq(fee, token.balanceOf(address(tokenMessengerWithMetadataWrapper)));

        snapEnd();
    }

    // depositForBurnPermit
    function testDepositForBurnPermitSuccess(
        uint256 _amount
    ) public {

        snapStart("depositForBurnPermitSuccess");

        vm.assume(_amount > 5);
        vm.assume(_amount <= ALLOWED_BURN_AMOUNT);

        uint16 _percFee = 1;
        uint64 _flatFee = 0;
        bytes32 _mintRecipient = Message.addressToBytes32(address(0x10));

        vm.prank(FEE_UPDATER);
        tokenMessengerWithMetadataWrapper.setFee(REMOTE_DOMAIN, _percFee, _flatFee);

        // max permit
        uint256 ownerPrivateKey = 0xA11CE;
        address owner = vm.addr(ownerPrivateKey); // 0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7
        token.mint(owner, _amount);

        SigUtils.Permit memory permit = SigUtils.Permit({
            owner: owner,
            spender: address(tokenMessengerWithMetadataWrapper),
            value: _amount,
            nonce: token.nonces(owner),
            deadline: 1 days
        });

        bytes32 digest = sigUtils.getTypedDataHash(permit);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        uint256 feeCollected = (_percFee * _amount / 10000) + _flatFee;
        vm.expectEmit(true, true, true, true);
        emit Collect(_mintRecipient, _amount - feeCollected, feeCollected, LOCAL_DOMAIN, REMOTE_DOMAIN);

        vm.startPrank(owner);
        tokenMessengerWithMetadataWrapper.depositForBurnPermit(
            _amount,
            REMOTE_DOMAIN,
            _mintRecipient,
            permit.deadline,
            v,
            r,
            s
        );
        vm.stopPrank();

        assertEq(0, token.balanceOf(owner));
        assertEq(feeCollected, token.balanceOf(address(tokenMessengerWithMetadataWrapper)));

        snapEnd();
    }

    // depositForBurnIBC
    function testDepositForBurnIBCSuccess(
        uint256 _amount,
        uint16 _percFee,
        uint64 _flatFee
    ) public {
        vm.assume(_amount > 0);
        vm.assume(_amount <= ALLOWED_BURN_AMOUNT);
        vm.assume(_percFee > 0);
        vm.assume(_percFee <= 100);
        vm.assume(_flatFee + _percFee * _amount / 10000 < _amount);

        bytes32 _mintRecipient = Message.addressToBytes32(address(0x10));

        token.mint(OWNER, _amount);
        vm.prank(FEE_UPDATER);
        tokenMessengerWithMetadataWrapper.setFee(REMOTE_DOMAIN, _percFee, _flatFee);

        vm.prank(OWNER);
        token.approve(address(tokenMessengerWithMetadataWrapper), _amount);

        vm.expectEmit(true, true, true, true);
        uint256 fee = (_amount * _percFee / 10000) + _flatFee;
        emit Collect(_mintRecipient, _amount - fee, fee, LOCAL_DOMAIN, REMOTE_DOMAIN);

        vm.prank(OWNER);
        tokenMessengerWithMetadataWrapper.depositForBurnIBC(
            uint64(0),
            bytes32(0),
            bytes32(0),
            _amount,
            _mintRecipient,
            ""
        );

        assertEq(0, token.balanceOf(OWNER));
        assertEq(fee, token.balanceOf(address(tokenMessengerWithMetadataWrapper)));
    }

    // depositForBurnIBCPermit
    function testDepositForBurnIBCPermitSuccess() public {

        snapStart("depositForBurnIBCPermitSuccess");

        uint16 _percFee = 0;
        uint64 _flatFee = 2;
        bytes32 _mintRecipient = Message.addressToBytes32(address(0x10));

        vm.prank(FEE_UPDATER);
        tokenMessengerWithMetadataWrapper.setFee(REMOTE_DOMAIN, _percFee, _flatFee);

        // max permit
        uint256 ownerPrivateKey = 0xA11CE;
        address owner = vm.addr(ownerPrivateKey); // 0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7
        token.mint(owner, 55);

        SigUtils.Permit memory permit = SigUtils.Permit({
            owner: owner,
            spender: address(tokenMessengerWithMetadataWrapper),
            value: 55,
            nonce: token.nonces(owner),
            deadline: 1 days
        });

        bytes32 digest = sigUtils.getTypedDataHash(permit);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        uint256 feeCollected = (_percFee * 55 / 10000) + _flatFee;
        vm.expectEmit(true, true, true, true);
        emit Collect(_mintRecipient, 55 - feeCollected, feeCollected, LOCAL_DOMAIN, REMOTE_DOMAIN);

        vm.startPrank(owner);
        tokenMessengerWithMetadataWrapper.depositForBurnIBCPermit(
            uint64(0),
            bytes32(0),
            bytes32(0),
            55,
            _mintRecipient,
            "",
            permit.deadline,
            v,
            r,
            s
        );
        vm.stopPrank();

        assertEq(0, token.balanceOf(owner));
        assertEq(feeCollected, token.balanceOf(address(tokenMessengerWithMetadataWrapper)));

        snapEnd();
    }

    function testNotFeeUpdater() public {
        vm.expectRevert(Unauthorized.selector);
        vm.prank(OWNER);
        tokenMessengerWithMetadataWrapper.setFee(3, 0, 0);
    }

    function testSetFeeTooHigh() public {
        vm.expectRevert(PercFeeTooHigh.selector);
        vm.prank(FEE_UPDATER);
        tokenMessengerWithMetadataWrapper.setFee(3, 10001, 15); // 100.01%
    }

    function testSetFeeSuccess(
        uint16 _percFee,
        uint64 _flatFee
    ) public {
        _percFee = uint16(bound(_percFee, 1, 100)); // 1%
        vm.prank(FEE_UPDATER);
        tokenMessengerWithMetadataWrapper.setFee(3, _percFee, _flatFee);
    }

    function testWithdrawFeesWhenNotCollector() public {
        vm.expectRevert(Unauthorized.selector);
        vm.prank(OWNER);
        tokenMessengerWithMetadataWrapper.setFee(3, 1, 15);
    }

    function testWithdrawFeesSuccess() public {
        vm.prank(FEE_UPDATER);
        tokenMessengerWithMetadataWrapper.setFee(3, 1, 15);
        assertEq(0, token.balanceOf(address(tokenMessengerWithMetadataWrapper)));
    }
}
