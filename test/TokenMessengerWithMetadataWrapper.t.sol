// SPDX-License-Identifier: Apache-2.0

pragma solidity 0.8.22;

import "evm-cctp-contracts/src/TokenMessenger.sol";
import "evm-cctp-contracts/src/messages/Message.sol";
import "evm-cctp-contracts/src/messages/BurnMessage.sol";
import "evm-cctp-contracts/src/MessageTransmitter.sol";
import "evm-cctp-contracts/test/TestUtils.sol";
import "../src/TokenMessengerWithMetadataWrapper.sol";

contract TokenMessengerWithMetadataWrapperTest is Test, TestUtils {
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
    error TokenMessengerWithMetadataNotSet();
    error TokenNotSupported();
    error FeeNotFound();
    error BurnAmountTooLow();
    error NotFeeUpdater();
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
    address public constant USDC_ADDRESS = address(0x4);

    uint32 public constant ALLOWED_BURN_AMOUNT = 42000000;
    MockMintBurnToken public token = new MockMintBurnToken();
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
            USDC_ADDRESS
        );

        vm.prank(FEE_UPDATER);
        tokenMessengerWithMetadataWrapper.setFee(REMOTE_DOMAIN, 0, 0);

        tokenMessenger.addLocalMinter(address(tokenMinter));
        tokenMessenger.addRemoteTokenMessenger(
            REMOTE_DOMAIN, REMOTE_TOKEN_MESSENGER
        );

        linkTokenPair(
            tokenMinter, address(token), REMOTE_DOMAIN, REMOTE_TOKEN_MESSENGER
        );
        tokenMinter.addLocalTokenMessenger(address(tokenMessenger));

        vm.prank(tokenController);
        tokenMinter.setMaxBurnAmountPerMessage(
            address(token), ALLOWED_BURN_AMOUNT
        );
    }

    // ============ Tests ============
    function testConstructor_rejectsZeroAddressTokenMessenger() public {
        vm.expectRevert(TokenMessengerWithMetadataNotSet.selector);

        tokenMessengerWithMetadataWrapper = new TokenMessengerWithMetadataWrapper(
            address(tokenMessenger),
            address(0),
            LOCAL_DOMAIN,
            COLLECTOR,
            FEE_UPDATER,
            USDC_ADDRESS
        );
    }

    function testConstructor_rejectsZeroAddressTokenMessengerWithMetadata() public {
        vm.expectRevert(TokenMessengerNotSet.selector);

        tokenMessengerWithMetadataWrapper = new TokenMessengerWithMetadataWrapper(
            address(0),
            address(tokenMessengerWithMetadata),
            LOCAL_DOMAIN,
            COLLECTOR,
            FEE_UPDATER,
            USDC_ADDRESS
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
            _mintRecipientRaw,
            bytes32(0)
        );
    }

    // depositForBurn - no caller, $20 burn, 10 bips fee
    function testDepositForBurnSuccess(
        uint256 _amount,
        address _mintRecipient
    ) public {
        _amount = 20000000; // $20

        vm.assume(_mintRecipient != address(0));
        bytes32 _mintRecipientRaw = Message.addressToBytes32(_mintRecipient);

        token.mint(OWNER, _amount);
        vm.prank(FEE_UPDATER);
        tokenMessengerWithMetadataWrapper.setFee(REMOTE_DOMAIN, 10, 0); // 10 bips or 0.1%

        vm.prank(OWNER);
        token.approve(address(tokenMessengerWithMetadataWrapper), _amount);

        vm.expectEmit(true, true, true, true);
        emit Collect(_mintRecipientRaw, 19980000, 20000, LOCAL_DOMAIN, REMOTE_DOMAIN);

        vm.prank(OWNER);
        tokenMessengerWithMetadataWrapper.depositForBurn(
            _amount,
            REMOTE_DOMAIN,
            _mintRecipientRaw,
            bytes32(0)
        );

        assertEq(0, token.balanceOf(OWNER));
    }

    // depositForBurn - with caller, $20 burn, 10 bips fee
    function testDepositForBurnWithCallerSuccess(
        uint256 _amount,
        address _mintRecipient
    ) public {
        _amount = 20000000; // $20

        vm.assume(_mintRecipient != address(0));
        bytes32 _mintRecipientRaw = Message.addressToBytes32(_mintRecipient);

        token.mint(OWNER, _amount);
        vm.prank(FEE_UPDATER);
        tokenMessengerWithMetadataWrapper.setFee(REMOTE_DOMAIN, 10, 0); // 10 bips or 0.1%

        vm.prank(OWNER);
        token.approve(address(tokenMessengerWithMetadataWrapper), _amount);

        vm.expectEmit(true, true, true, true);
        emit Collect(_mintRecipientRaw, 19980000, 20000, LOCAL_DOMAIN, REMOTE_DOMAIN);

        vm.prank(OWNER);
        tokenMessengerWithMetadataWrapper.depositForBurn(
            _amount,
            REMOTE_DOMAIN,
            _mintRecipientRaw,
            0x0000000000000000000000000000000000000000000000000000000000000001
        );

        assertEq(0, token.balanceOf(OWNER));
    }

    // depositForBurn - no caller, $20 burn, 10 bips fee, some tokens left
    function testDepositForBurnWithSomeRemainingTokensSuccess(
        uint256 _amount,
        address _mintRecipient
    ) public {
        _amount = 20000000; // $20

        vm.assume(_mintRecipient != address(0));
        bytes32 _mintRecipientRaw = Message.addressToBytes32(_mintRecipient);

        token.mint(OWNER, _amount);
        vm.prank(FEE_UPDATER);
        tokenMessengerWithMetadataWrapper.setFee(REMOTE_DOMAIN, 0, 2000000); // $2

        vm.prank(OWNER);
        token.approve(address(tokenMessengerWithMetadataWrapper), _amount);

        vm.expectEmit(true, true, true, true);
        emit Collect(_mintRecipientRaw, 8000000, 2000000, LOCAL_DOMAIN, REMOTE_DOMAIN);

        vm.prank(OWNER);
        tokenMessengerWithMetadataWrapper.depositForBurn(
            10000000,
            REMOTE_DOMAIN,
            _mintRecipientRaw,
            bytes32(0)
        );

        assertEq(10000000, token.balanceOf(OWNER));
    }

    // depositForBurn - $20 burn, $4 flat fee
    function testDepositForBurn_flatFee(
        uint256 _amount,
        address _mintRecipient
    ) public {
        _amount = 20000000; // $20

        vm.assume(_mintRecipient != address(0));
        bytes32 _mintRecipientRaw = Message.addressToBytes32(_mintRecipient);

        token.mint(OWNER, _amount);
        vm.prank(FEE_UPDATER);
        tokenMessengerWithMetadataWrapper.setFee(REMOTE_DOMAIN, 0, 4000000); // $4

        vm.startPrank(OWNER);
        token.approve(address(tokenMessengerWithMetadataWrapper), _amount);

        vm.expectEmit(true, true, true, true);
        emit Collect(_mintRecipientRaw, 16000000, 4000000, LOCAL_DOMAIN, REMOTE_DOMAIN);

        tokenMessengerWithMetadataWrapper.depositForBurn(
            _amount,
            REMOTE_DOMAIN,
            _mintRecipientRaw,
            bytes32(0)
        );
        vm.stopPrank();

        assertEq(0, token.balanceOf(OWNER));
    }

    // depositForBurn - $20 burn, 10 bips flat fee
    function testDepositForBurn_percFee(
        uint256 _amount,
        address _mintRecipient
    ) public {
        _amount = 20000000; // $20

        vm.assume(_mintRecipient != address(0));
        bytes32 _mintRecipientRaw = Message.addressToBytes32(_mintRecipient);

        token.mint(OWNER, _amount);
        vm.prank(FEE_UPDATER);
        tokenMessengerWithMetadataWrapper.setFee(REMOTE_DOMAIN, 10, 0); // 10 bips or 0.1%

        vm.prank(OWNER);
        token.approve(address(tokenMessengerWithMetadataWrapper), _amount);

        vm.expectEmit(true, true, true, true);
        emit Collect(_mintRecipientRaw, 19980000, 20000, LOCAL_DOMAIN, REMOTE_DOMAIN);

        vm.prank(OWNER);
        tokenMessengerWithMetadataWrapper.depositForBurn(
            _amount,
            REMOTE_DOMAIN,
            _mintRecipientRaw,
            bytes32(0)
        );

        assertEq(0, token.balanceOf(OWNER));
    }

    // depositForBurn - $20 burn, 10 bips flat fee
    function testDepositForBurnCombinedFee(
        uint256 _amount,
        address _mintRecipient
    ) public {
        _amount = 20000000; // $20

        vm.assume(_mintRecipient != address(0));
        bytes32 _mintRecipientRaw = Message.addressToBytes32(_mintRecipient);

        token.mint(OWNER, _amount);
        vm.prank(FEE_UPDATER);
        tokenMessengerWithMetadataWrapper.setFee(REMOTE_DOMAIN, 10, 2000000); // 10 bips or 0.1% + $2

        vm.prank(OWNER);
        token.approve(address(tokenMessengerWithMetadataWrapper), _amount);

        vm.expectEmit(false, false, false, true);
        emit Collect(_mintRecipientRaw, 17980000, 2020000, LOCAL_DOMAIN, REMOTE_DOMAIN);

        vm.prank(OWNER);
        tokenMessengerWithMetadataWrapper.depositForBurn(
            _amount,
            REMOTE_DOMAIN,
            _mintRecipientRaw,
            bytes32(0)
        );

        assertEq(0, token.balanceOf(OWNER));
    }

    // depositForBurn - no caller, $20 burn, 10 bips fee
    function testDepositForBurnIBCSuccess(
        uint256 _amount,
        address _mintRecipient
    ) public {
        _amount = 20000000; // $20

        vm.assume(_mintRecipient != address(0));
        bytes32 _mintRecipientRaw = Message.addressToBytes32(_mintRecipient);

        token.mint(OWNER, _amount);
        vm.prank(FEE_UPDATER);
        tokenMessengerWithMetadataWrapper.setFee(REMOTE_DOMAIN, 10, 0); // 10 bips or 0.1%

        vm.prank(OWNER);
        token.approve(address(tokenMessengerWithMetadataWrapper), _amount);

        //vm.expectEmit(false, false, false, true);
        //emit Collect(_mintRecipientRaw, 19980000, 20000, LOCAL_DOMAIN, REMOTE_DOMAIN);

        vm.prank(OWNER);
        tokenMessengerWithMetadataWrapper.depositForBurnIBC(
            uint64(0),
            bytes32(0),
            bytes32(0),
            _amount,
            _mintRecipientRaw,
            bytes32(0),
            ""
        );

        //assertEq(0, token.balanceOf(OWNER));
    }

    function testSetFeeHappyPath(
        uint16 _percFee
    ) public {
        _percFee = uint16(bound(_percFee, 1, 100)); // 1%
        vm.prank(FEE_UPDATER);
        tokenMessengerWithMetadataWrapper.setFee(3, _percFee, 15);
    }

    function testSetFeeTooHigh() public {
        vm.expectRevert(PercFeeTooHigh.selector);
        vm.prank(FEE_UPDATER);
        tokenMessengerWithMetadataWrapper.setFee(3, 10001, 15); // 100.01%
    }

    // depositForBurn - no fee set
    function testFeeNotFound(
        uint256 _amount,
        address _mintRecipient
    ) public {
        _amount = 4;

        vm.assume(_mintRecipient != address(0));
        bytes32 _mintRecipientRaw = Message.addressToBytes32(_mintRecipient);

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
            _mintRecipientRaw,
            bytes32(0)
        );
    }
}
