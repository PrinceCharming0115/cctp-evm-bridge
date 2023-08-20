//SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.19;

/**
 * @title ITokenMessenger
 * @notice Hasdf
 */
interface ITokenMessenger {
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken
    ) external;

    function depositForBurnWithCaller(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller
    ) external;
}
