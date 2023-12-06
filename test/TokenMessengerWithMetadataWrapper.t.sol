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

    event FastTransfer(
        bytes32 mintRecipient,
        uint256 amount,
        uint32 source,
        uint32 dest
    );

    event FastTransferIBC(
        bytes32 mintRecipient,
        uint256 amount,
        uint32 source,
        uint32 dest,
        uint64 channel,
        bytes32 destinationBech32Prefix,
        bytes32 destRecipient,
        bytes memo
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
            USDC_ADDRESS
        );
    }

    // depositForBurn - no fee set
    function testDepositForBurnFeeNotFound(
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

    // depositForBurn
    function testDepositForBurnSuccess(
        uint256 _amount,
        uint16 _percFee,
        uint64 _flatFee
    ) public {

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
            _mintRecipientRaw,
            bytes32(0)
        );

        assertEq(0, token.balanceOf(OWNER));
        assertEq(fee, token.balanceOf(address(tokenMessengerWithMetadataWrapper)));
    }

    // depositForBurn with caller
    function testDepositForBurnWithCallerSuccess(
        uint256 _amount,
        uint16 _percFee,
        uint64 _flatFee
    ) public {

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
            _mintRecipientRaw,
            0x0000000000000000000000000000000000000000000000000000000000000001
        );

        assertEq(0, token.balanceOf(OWNER));
        assertEq(fee, token.balanceOf(address(tokenMessengerWithMetadataWrapper)));
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
        tokenMessengerWithMetadataWrapper.depositForBurnIBC(
            uint64(0),
            bytes32(0),
            bytes32(0),
            _amount,
            _mintRecipientRaw,
            bytes32(0),
            ""
        );

        assertEq(0, token.balanceOf(OWNER));
        assertEq(fee, token.balanceOf(address(tokenMessengerWithMetadataWrapper)));
    }

    // fastTransfer
    function fastTransferSuccess(
        uint256 _amount
    ) public {
        vm.assume(_amount > 0);

        bytes32 _mintRecipientRaw = Message.addressToBytes32(address(0x10));

        token.mint(OWNER, _amount);
        vm.prank(FEE_UPDATER);
        tokenMessengerWithMetadataWrapper.setFee(REMOTE_DOMAIN, 0, 0);

        vm.prank(OWNER);
        token.approve(address(tokenMessengerWithMetadataWrapper), _amount);

        vm.expectEmit(true, true, true, true);
        emit FastTransfer(_mintRecipientRaw, _amount, LOCAL_DOMAIN, REMOTE_DOMAIN);

        vm.prank(OWNER);
        tokenMessengerWithMetadataWrapper.fastTransfer(
            _amount,
            REMOTE_DOMAIN,
            _mintRecipientRaw
        );

        assertEq(0, token.balanceOf(OWNER));
        assertEq(_amount, token.balanceOf(address(tokenMessengerWithMetadataWrapper)));
    }

    // fastTransferIBC
    function fastTransferIBCSuccess(
        uint256 _amount
    ) public {
        vm.assume(_amount > 0);

        bytes32 _mintRecipientRaw = Message.addressToBytes32(address(0x10));

        token.mint(OWNER, _amount);
        vm.prank(FEE_UPDATER);
        tokenMessengerWithMetadataWrapper.setFee(REMOTE_DOMAIN, 0, 0);

        vm.prank(OWNER);
        token.approve(address(tokenMessengerWithMetadataWrapper), _amount);

        vm.expectEmit(true, true, true, true);
        emit FastTransfer(_mintRecipientRaw, _amount, LOCAL_DOMAIN, REMOTE_DOMAIN);

        vm.prank(OWNER);
        tokenMessengerWithMetadataWrapper.fastTransferIBC(
            _amount, 
            _mintRecipientRaw, 
            uint64(0), 
            bytes32(0), 
            bytes32(0), 
            ""
        );

        assertEq(0, token.balanceOf(OWNER));
        assertEq(_amount, token.balanceOf(address(tokenMessengerWithMetadataWrapper)));
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

    // fastTransfer
    function testFastTransferHappyPath(
        address _mintRecipient
    ) public {

        uint256 _amount = 20000;

        vm.assume(_mintRecipient != address(0));
        bytes32 _mintRecipientRaw = Message.addressToBytes32(_mintRecipient);

        token.mint(owner, _amount);
        vm.prank(FEE_UPDATER);
        tokenMessengerWithMetadataWrapper.setFee(REMOTE_DOMAIN, 10, 0); // 10 bips or 0.1%

        tokenMessengerWithMetadataWrapper.allowToken(address(token));

        vm.prank(owner);
        token.approve(address(tokenMessengerWithMetadataWrapper), _amount);

        vm.expectEmit(true, true, true, true);
        emit FastTransfer(_amount, REMOTE_DOMAIN, _mintRecipientRaw, address(token), 0);

        vm.prank(owner);
        tokenMessengerWithMetadataWrapper.fastTransfer(
            _amount,
            REMOTE_DOMAIN,
            _mintRecipientRaw,
            address(token)
        );

        assertEq(0, token.balanceOf(owner));
        assertEq(20000, token.balanceOf(COLLECTOR));
    }

    // fastTransfer -> fail with weird token
    function testFastTransferDisallowedToken(
        address _mintRecipient
    ) public {

        uint256 _amount = 20000;

        vm.assume(_mintRecipient != address(0));
        bytes32 _mintRecipientRaw = Message.addressToBytes32(_mintRecipient);

        token.mint(owner, _amount);
        vm.prank(FEE_UPDATER);
        tokenMessengerWithMetadataWrapper.setFee(REMOTE_DOMAIN, 10, 0); // 10 bips or 0.1%

        vm.prank(owner);
        token.approve(address(tokenMessengerWithMetadataWrapper), _amount);

        vm.expectRevert("Token is not supported");

        vm.prank(owner);
        tokenMessengerWithMetadataWrapper.fastTransfer(
            _amount,
            REMOTE_DOMAIN,
            _mintRecipientRaw,
            address(token)
        );
    }

    // fastTransferIBC
    function testFastTransferIBCHappyPath(
        address _mintRecipient
    ) public {

        uint256 _amount = 20000;
        uint64 _channel = 3;
        bytes32 _destinationBech32Prefix = bytes32(0);
        bytes32 _destRecipient = bytes32(0);
        bytes memory _memo = "";

        vm.assume(_mintRecipient != address(0));
        bytes32 _mintRecipientRaw = Message.addressToBytes32(_mintRecipient);

        token.mint(owner, _amount);
        vm.prank(FEE_UPDATER);
        tokenMessengerWithMetadataWrapper.setFee(REMOTE_DOMAIN, 10, 0); // 10 bips or 0.1%

        tokenMessengerWithMetadataWrapper.allowToken(address(token));

        vm.prank(owner);
        token.approve(address(tokenMessengerWithMetadataWrapper), _amount);

        vm.expectEmit(true, true, true, true);
        emit FastTransferIBC(
            _amount, 
            REMOTE_DOMAIN,
            _mintRecipientRaw, 
            address(token), 
            0,
            _channel,
            _destinationBech32Prefix,
            _destRecipient,
            _memo
        );

        vm.prank(owner);
        tokenMessengerWithMetadataWrapper.fastTransferIBC(
            _amount,
            _mintRecipientRaw,
            address(token),
            _channel,
            _destinationBech32Prefix,
            _destRecipient,
            _memo
        );

        assertEq(0, token.balanceOf(owner));
        assertEq(20000, token.balanceOf(COLLECTOR));
    }

    // fastTransferIBC
    function testFastTransferIBCDisallowedToken(
        address _mintRecipient
    ) public {

        uint256 _amount = 20000;
        uint64 _channel = 3;
        bytes32 _destinationBech32Prefix = bytes32(0);
        bytes32 _destRecipient = bytes32(0);
        bytes memory _memo = "";

        vm.assume(_mintRecipient != address(0));
        bytes32 _mintRecipientRaw = Message.addressToBytes32(_mintRecipient);

        token.mint(owner, _amount);
        vm.prank(FEE_UPDATER);
        tokenMessengerWithMetadataWrapper.setFee(REMOTE_DOMAIN, 10, 0); // 10 bips or 0.1%

        vm.prank(owner);
        token.approve(address(tokenMessengerWithMetadataWrapper), _amount);

        vm.expectRevert("Token is not supported");

        vm.prank(owner);
        tokenMessengerWithMetadataWrapper.fastTransferIBC(
            _amount,
            _mintRecipientRaw,
            address(token),
            _channel,
            _destinationBech32Prefix,
            _destRecipient,
            _memo
        );

    }
}
