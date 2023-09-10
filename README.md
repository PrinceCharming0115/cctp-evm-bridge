# cctp-money-bridge-contracts

<h2>Contract addresses</h2>

<h3>Testnets</h3>

| Chain              | Domain Id | Address |
| :----------------- | :-------- | -------: |
| Ethereum Goerli    |   0       | 0x1234 |
| Avalanche          |   1       |  |
| OP Goerli          |   2       |  |
| Arbitrum Goerli    |   3       |  |
| Noble testnet      |   4       |  |

<h3>Mainnets</h3>

| Chain              | Domain Id | Address |
| :----------------- | :-------- | -------: |
| Ethereum           |   0       | 0x1234 |
| Avalanche          |   1       |  |
| Optimism           |   2       |  |
| Arbitrum           |   3       |  |
| Noble              |   4       |  |

<h2>Channel ID -> Cosmos chain mappings</h2>

https://github.com/cosmos/chain-registry/blob/master/noble/assetlist.json\
https://github.com/cosmos/chain-registry/blob/master/testnets/nobletestnet/assetlist.json

| Channel ID         | Chain |
| :----------------- | :-------- |
| 0                  |   dydx mainnet |

<h2>Request payloads</h2>

Before any burns, the user must approve the transfer.  For reference we are using ~300k gas (I think).
```
const approveTx = await usdcEthContract.methods.approve(
    ETH_TOKEN_MESSENGER_WITH_METADATA_WRAPPER_CONTRACT_ADDRESS, 
    amount).send({gas: approveTxGas})
```

DepositForBurn is for a simple burn and mint to any destination chain.
```
{
    depositForBurn(
        uint256 amount,           // all usdc has 6 decimals, so $1 = 10^6 usdc
        uint32 destinationDomain, // domain id the funds will be minted on
        bytes32 mintRecipient,    // address receiving minted tokens on destination domain
        address burnToken,        // address of the token being burned on the source chain
        bytes32 destinationCaller // (optional) address allowed to mint on destination domain
    )
}
```

DepositForBurnNoble is minting+forwarding on Noble.  IBC forwarding metadata can be included in the payload.
```
{
    depositForBurn(
        uint64 channel,                   // channel id to be used when ibc forwarding
        bytes32 destinationBech32Prefix,  // bech32 prefix used for address encoding once ibc forwarded
        bytes32 destinationRecipient,     // address of the recipient after the IBC forward
        uint256 amount,                   // all usdc has 6 decimals, so $1 = 10^6 usdc
        bytes32 mintRecipient,            // address receiving minted tokens on destination domain
        address burnToken,                // address of the token being burned on the source chain
        bytes32 destinationCaller,        // (optional) address allowed to mint on destination domain
        bytes calldata memo               // memo to include in the message
    )
}
```


TODO: Burn on Noble
TODO: Burn on Cosmos chain, ibc forward, burn on Noble
