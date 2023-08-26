pragma solidity 0.7.6;

import "evm-cctp-contracts/src/TokenMessenger.sol";
import "evm-cctp-contracts/src/messages/Message.sol";
import "evm-cctp-contracts/src/messages/BurnMessage.sol";
import "evm-cctp-contracts/src/MessageTransmitter.sol";
import "evm-cctp-contracts/test/TestUtils.sol";
import "../src/TokenMessengerWithMetadata.sol";

contract TokenMessengerWithMetadataTest is Test, TestUtils {
    // ============ Events ============
    event Collect(
        address indexed burnToken, 
        bytes32 mintRecipient, 
        uint256 amountBurned, 
        uint256 fee,
        uint32 source, 
        uint32 dest
    );

    // ============ State Variables ============
    uint32 public constant LOCAL_DOMAIN = 0;
    uint32 public constant MESSAGE_BODY_VERSION = 1;

    uint32 public constant REMOTE_DOMAIN = 4;
    bytes32 public constant REMOTE_TOKEN_MESSENGER =
        0x00000000000000000000000057d4eaf1091577a6b7d121202afbd2808134f117;

    address payable public constant COLLECTOR = address(0x1);

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
    TokenMessengerWithMetadata public tokenMessengerWrapper;

    // ============ Setup ============
    function setUp() public {
        tokenMessenger = new TokenMessenger(
            address(messageTransmitter),
            MESSAGE_BODY_VERSION
        );
        tokenMessengerWrapper = new TokenMessengerWithMetadata(
            address(tokenMessenger),
            REMOTE_DOMAIN,
            REMOTE_TOKEN_MESSENGER,
            LOCAL_DOMAIN,
            COLLECTOR
        );

        tokenMessengerWrapper.setFee(REMOTE_DOMAIN, 0, 0);

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
        vm.expectRevert("TokenMessenger not set");

        tokenMessengerWrapper = new TokenMessengerWithMetadata(
            address(0),
            REMOTE_DOMAIN,
            REMOTE_TOKEN_MESSENGER,
            LOCAL_DOMAIN,
            COLLECTOR
        );
    }

    function testDepositForBurn_success(
        uint256 _amount,
        address _mintRecipient
    ) public {
        _amount = 20000000; // $20

        vm.assume(_mintRecipient != address(0));
        bytes32 _mintRecipientRaw = Message.addressToBytes32(_mintRecipient);

        token.mint(owner, _amount);
        tokenMessengerWrapper.setFee(REMOTE_DOMAIN, 10, 0); // 10 bips or 0.001%

        vm.prank(owner);
        token.approve(address(tokenMessengerWrapper), _amount);

        vm.prank(owner);
        tokenMessengerWrapper.depositForBurn(
            _amount,
            REMOTE_DOMAIN,
            _mintRecipientRaw,
            address(token),
            bytes32(0)
        );

        assertEq(0, token.balanceOf(owner));
        assertEq(20000, token.balanceOf(COLLECTOR));
    }

    function testDepositForBurn_someRemainingTokensSuccess(
        uint256 _amount,
        address _mintRecipient
    ) public {
        _amount = 20000000; // $20

        vm.assume(_mintRecipient != address(0));
        bytes32 _mintRecipientRaw = Message.addressToBytes32(_mintRecipient);

        token.mint(owner, _amount);
        tokenMessengerWrapper.setFee(REMOTE_DOMAIN, 0, 2000000); // $2

        vm.prank(owner);
        token.approve(address(tokenMessengerWrapper), _amount);

        vm.prank(owner);
        tokenMessengerWrapper.depositForBurn(
            10000000,
            REMOTE_DOMAIN,
            _mintRecipientRaw,
            address(token),
            bytes32(0)
        );

        assertEq(10000000, token.balanceOf(owner));
        assertEq(2000000, token.balanceOf(COLLECTOR));
    }

    function testRawDepositForBurn_succeeds(
        uint256 _amount,
        address _mintRecipient
    ) public {
        _amount = bound(_amount, 1, ALLOWED_BURN_AMOUNT);

        vm.assume(_mintRecipient != address(0));
        bytes32 _mintRecipientRaw = Message.addressToBytes32(_mintRecipient);

        bytes memory metadata = "";

        token.mint(owner, _amount * 2);

        vm.prank(owner);
        token.approve(address(tokenMessengerWrapper), _amount);

        vm.prank(owner);
        tokenMessengerWrapper.rawDepositForBurn(
            _amount, _mintRecipientRaw, address(token), metadata
        );

        assertEq(_amount, token.balanceOf(owner));
        assertEq(0, token.balanceOf(COLLECTOR));
    }

    function testRawDepositForBurnWithCaller_succeeds(
        uint256 _amount,
        address _mintRecipient
    ) public {
        _amount = bound(_amount, 1, ALLOWED_BURN_AMOUNT);

        vm.assume(_mintRecipient != address(0));
        bytes32 _mintRecipientRaw = Message.addressToBytes32(_mintRecipient);

        bytes memory metadata = "";

        token.mint(owner, _amount * 2);

        vm.prank(owner);
        token.approve(address(tokenMessengerWrapper), _amount);

        vm.prank(owner);
        tokenMessengerWrapper.rawDepositForBurnWithCaller(
            _amount,
            _mintRecipientRaw,
            address(token),
            destinationCaller,
            metadata
        );

        assertEq(_amount, token.balanceOf(owner));
        assertEq(0, token.balanceOf(COLLECTOR));
    }

    function testRawDepositForBurn_flatFee(
        uint256 _amount,
        address _mintRecipient
    ) public {
        _amount = 20000000; // $20

        vm.assume(_mintRecipient != address(0));
        bytes32 _mintRecipientRaw = Message.addressToBytes32(_mintRecipient);

        bytes memory metadata = "";

        token.mint(owner, _amount);
        tokenMessengerWrapper.setFee(REMOTE_DOMAIN, 0, 4000000); // $4

        vm.startPrank(owner);
        token.approve(address(tokenMessengerWrapper), _amount);

        vm.expectEmit(true, true, true, true);
        emit Collect(address(token), _mintRecipientRaw, 20000000, 4000000, LOCAL_DOMAIN, REMOTE_DOMAIN);

        tokenMessengerWrapper.rawDepositForBurn(
            _amount,
            _mintRecipientRaw,
            address(token),
            metadata
        );
        vm.stopPrank();

        assertEq(0, token.balanceOf(owner));
        assertEq(4000000, token.balanceOf(COLLECTOR));
    }

    function testRawDepositForBurn_percFee(
        uint256 _amount,
        address _mintRecipient
    ) public {
        _amount = 20000000; // $20

        vm.assume(_mintRecipient != address(0));
        bytes32 _mintRecipientRaw = Message.addressToBytes32(_mintRecipient);

        bytes memory metadata = "";

        token.mint(owner, _amount);
        tokenMessengerWrapper.setFee(REMOTE_DOMAIN, 10, 0); // 10 bips or 0.001%

        vm.prank(owner);
        token.approve(address(tokenMessengerWrapper), _amount);

        //
        vm.prank(owner);
        tokenMessengerWrapper.rawDepositForBurn(
            _amount,
            _mintRecipientRaw,
            address(token),
            metadata
        );

        assertEq(0, token.balanceOf(owner));
        assertEq(_amount / 1000, token.balanceOf(COLLECTOR));
    }
}
