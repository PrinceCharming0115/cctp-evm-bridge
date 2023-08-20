//SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.19;

/**
 * @title ITokenMessengerWithMetadata
 * @notice Hasdf
 */
interface ITokenMessengerWithMetadata {
    function depositForBurn(
        uint64 channel,
        bytes32 destinationRecipient,
        uint256 amount, 
        bytes32 mintRecipient, 
        address burnToken,
        bytes calldata memo
    ) external;

    function rawDepositForBurn(
        uint256 amount,
        bytes32 mintRecipient,
        address burnToken,
        bytes memory metadata
    ) external;

    function depositForBurnWithCaller(
        uint64 channel,
        bytes32 destinationRecipient,
        uint256 amount,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        bytes calldata memo
    ) external;

    function rawDepositForBurnWithCaller(
        uint256 amount,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        bytes memory metadata
    ) external;
}
